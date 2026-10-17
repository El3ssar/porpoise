import Combine
import Foundation
import PorpoiseCore

/// Main-thread account metadata and lifecycle. Credentials never enter UserDefaults or notifications.
@MainActor
public final class DriveAccountStore: ObservableObject {
    public static let shared = DriveAccountStore()
    public static let changed = Notification.Name("PorpoiseDriveAccountsChanged")
    @Published public private(set) var accounts: [DriveAccount] = []
    /// OK, offline or waiting to be signed in again, per account.
    public let status = CloudAccountStatus()
    private let signIn = CloudSignIn(provider: "Google Drive")
    public var connecting: Bool { signIn.inProgress }
    private struct Profile: Decodable { var sub: String; var email: String; var name: String?; var picture: URL? }
    private let defaults: UserDefaults
    private let credentials: any DriveCredentialStore
    private let http: DriveHTTP
    private let configuration: DriveOAuthConfiguration?
    private let baseURL: URL
    private let records: CloudAccountRecords<DriveAccount>
    private var saved: [CloudAccountRecords<DriveAccount>.Record] = []
    private var clients: [UUID: DriveClient] = [:]
    @Published public private(set) var writeAccess: [UUID: Bool] = [:]
    public func hasWriteAccess(_ accountID: UUID) -> Bool { writeAccess[accountID] == true }
    private var managers: [UUID: DriveTokenManager] = [:]

    public init(
        defaults: UserDefaults = Settings.store, credentials: any DriveCredentialStore = CredentialStores.drive(),
        http: DriveHTTP = DriveHTTP(), configuration: DriveOAuthConfiguration? = nil,
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3/")!
    ) {
        self.defaults = defaults; self.credentials = credentials; self.http = http
        records = CloudAccountRecords(defaults: defaults, key: "googleDriveAccounts", clientField: "clientID")
        if configuration == nil, Settings.isTesting,
            let raw = TestEnvironment.driveFake.value(), let fake = URL(string: raw),
            fake.scheme == "http", fake.host == "127.0.0.1"
        {
            self.configuration = DriveOAuthConfiguration(
                clientID: "porpoise-fixture", authorizationURL: fake.appendingPathComponent("auth"),
                tokenURL: fake.appendingPathComponent("token"), revokeURL: fake.appendingPathComponent("revoke"),
                profileURL: fake.appendingPathComponent("userinfo"))
            self.baseURL = fake.appendingPathComponent("drive/v3/")
        } else {
            self.configuration = configuration; self.baseURL = baseURL
        }
        saved = records.load()
        accounts = saved.map(\.account)
        for record in saved { install(record.account, config: config(clientID: record.clientID)) }
        status.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    public var clientIDOverride: String {
        get { defaults.string(forKey: "googleDriveClientID") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "googleDriveClientID") }
    }

    private func config(clientID: String? = nil) -> DriveOAuthConfiguration {
        if var configuration {
            if let clientID { configuration.clientID = clientID }
            return configuration
        }
        // Overrides (environment, the hidden default) are for test instances only: a release uses the client it was built with.
        let env = Settings.isTesting ? ProcessInfo.processInfo.environment : [:]
        let override = Settings.isTesting && !clientIDOverride.isEmpty ? clientIDOverride : nil
        let selected =
            clientID ?? TestEnvironment.googleClientID.value(in: env) ?? override
            ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientID") as? String) ?? ""
        return DriveOAuthConfiguration(
            clientID: selected,
            clientSecret: TestEnvironment.googleClientSecret.value(in: env)
                ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientSecret") as? String))
    }

    private func install(_ account: DriveAccount, config: DriveOAuthConfiguration, authenticated: DriveTokenManager? = nil) {
        let manager = authenticated ?? DriveTokenManager(configuration: config, accountID: account.id, credentials: credentials, http: http)
        (RemoteFS.provider(for: DriveLocation(accountID: account.id).url) as? DriveProvider)?.invalidate()
        let client = DriveClient(accountID: account.id, tokens: manager, http: http, baseURL: baseURL) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.status.record(
                    account.id, error, signInNeeded: (error as? DriveError) == .reconnect, skipped: (error as? DriveError) == .offline)
            }
        }
        status.track(account.id)
        client.startPolling()
        writeAccess[account.id] = nil
        Task { @MainActor [weak self] in
            let allowed = (try? await manager.requireWriteScope()) != nil
            guard self?.managers[account.id] === manager else { return }
            self?.writeAccess[account.id] = allowed
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        managers[account.id] = manager; clients[account.id] = client
        RemoteFS.registerDrive(
            DriveProvider(accountID: account.id, client: client, accountName: account.displayName, accountEmail: account.email), accountID: account.id
        )
    }

    private func persist() throws {
        try records.save(saved)
        accounts = saved.map(\.account)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func client(for accountID: UUID) -> DriveClient? { clients[accountID] }

    @discardableResult
    public func connect(openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DriveAccount {
        try await authenticate(expected: nil, openBrowser: openBrowser)
    }

    @discardableResult
    public func reauthorize(_ account: DriveAccount, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DriveAccount {
        try await authenticate(expected: account, openBrowser: openBrowser)
    }

    private func authenticate(expected: DriveAccount?, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DriveAccount {
        let config = config(clientID: expected.flatMap { account in saved.first { $0.account.id == account.id }?.clientID })
        return try await signIn.run(
            listener: { () throws -> DriveLoopback in
                guard !config.clientID.isEmpty else { throw DriveError.configuration }
                return try DriveLoopback()
            }, email: \.email
        ) { listener in
            let transaction = try DriveOAuthTransaction(configuration: config, redirectURL: listener.redirectURL, loginHint: expected?.email)
            openBrowser(transaction.authorizationURL)
            let callback = try await listener.callback()
            let token = try await transaction.exchange(callback, http: http)
            try Task.checkCancellation()
            var request = URLRequest(url: config.profileURL)
            request.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
            let data = try await http.data(request)
            guard let profile = try? JSONDecoder().decode(Profile.self, from: data), !profile.sub.isEmpty, !profile.email.isEmpty else {
                throw DriveError.invalidResponse
            }
            let existing = saved.first { $0.account.subject == profile.sub && $0.clientID == config.clientID }
            try CloudSignIn.check(expected: expected?.id, isExpected: expected?.subject == profile.sub, existing: existing?.account.id)
            let account = DriveAccount(
                id: existing?.account.id ?? UUID(), subject: profile.sub, email: profile.email,
                displayName: profile.name ?? profile.email, photoURL: profile.picture?.scheme == "https" ? profile.picture : nil)
            // Consent is requested so the first connection must provide a refresh credential.
            guard try token.refresh_token != nil || credentials.read(clientID: config.clientID, accountID: account.id) != nil else {
                throw DriveError.reconnect
            }
            let manager = DriveTokenManager(configuration: config, accountID: account.id, credentials: credentials, http: http)
            try await manager.accept(token)
            await clients[account.id]?.clearCaches()
            install(account, config: config, authenticated: manager)
            saved.removeAll { $0.account.id == account.id }
            saved.append(.init(account: account, clientID: config.clientID))
            try persist()
            return account
        }
    }

    public func disconnect(_ account: DriveAccount) async throws {
        guard let manager = managers[account.id] else { return }
        if let client = clients[account.id], !(await client.edits.pending()).isEmpty { throw CloudConnectionError.unsentEdits }
        var failure: Error?
        do { try await manager.revoke() } catch let error as DriveError {
            if case .keychain = error { throw error }
            failure = error
        } catch { failure = error }
        (RemoteFS.provider(for: DriveLocation(accountID: account.id).url) as? DriveProvider)?.invalidate()
        let key = account.id.uuidString.lowercased()
        if let client = clients[account.id] { _ = try await client.offlineCopies() }
        try await CloudAccountWipe.offlineCopies(key)
        if let client = clients[account.id] {
            await client.clearCaches()
            try await forgetLocalData(client, manager: manager)
        }
        managers[account.id] = nil; clients[account.id] = nil; status.forget(account.id)
        RemoteFS.unregisterDrive(accountID: account.id)
        saved.removeAll { $0.account.id == account.id }
        try persist()
        if let failure { throw failure }
    }
}

extension DriveAccountStore {
    /// Sign-out leaves nothing of the account on this Mac: its folder (metadata, previews, opened and edited copies,
    /// conflict copies), its transfer records with their partial downloads, and their upload sessions in the Keychain.
    func forgetLocalData(_ client: DriveClient, manager: DriveTokenManager) async throws {
        let journal = client.mutationJournal
        for record in try journal.all(accountID: client.accountID) {
            if record.hasSession { try await manager.removeSession(record.operationID) }
            for id in [record.operationID, record.downloadOperationID].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: journal.partial(id))
            }
            try journal.remove(record.operationID)
        }
        for folder in [client.metadataCache.directory, client.offlineDirectory].compactMap({ $0 }) { try CloudAccountWipe.remove(folder) }
    }
}
