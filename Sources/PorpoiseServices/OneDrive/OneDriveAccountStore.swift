import Foundation
import PorpoiseCore

/// OneDrive accounts: PKCE loopback sign-in, the same person checks, refresh credentials, persisted account metadata,
/// reconnect and disconnect.
@MainActor public final class OneDriveAccountStore {
    public static let shared = OneDriveAccountStore(directory: defaultDirectory)
    static var defaultDirectory: URL {
        if CredentialStores.isIsolated, !Settings.isTesting {
            let suite = TestEnvironment.defaultsSuite.value() ?? "tests"
            return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-onedrive-" + cloudObjectKey(suite))
        }
        return Settings.supportFolder.appendingPathComponent("OneDrive")
    }
    public private(set) var accounts: [OneDriveAccount] = []
    /// OK, offline or waiting to be signed in again, per account.
    public let status = CloudAccountStatus()
    private let signIn = CloudSignIn(provider: "OneDrive")
    public var connecting: Bool { signIn.inProgress }
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let credentials: any CloudCredentialStore
    private let configuration: OneDriveConfiguration?
    private let http: CloudHTTPTransport
    private let directory: URL
    private let records: CloudAccountRecords<OneDriveAccount>
    private var saved: [CloudAccountRecords<OneDriveAccount>.Record] = []
    private var clients: [UUID: OneDriveClient] = [:]
    public init(
        defaults: UserDefaults = Settings.store, credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "onedrive"),
        configuration: OneDriveConfiguration? = nil, directory: URL, http: CloudHTTPTransport = .init()
    ) {
        self.defaults = defaults; self.credentials = credentials; self.directory = directory; self.http = http
        records = CloudAccountRecords(defaults: defaults, key: "oneDriveAccounts", clientField: "clientID")
        if configuration == nil, Settings.isTesting, let raw = TestEnvironment.oneDriveFake.value(),
            let fake = URL(string: raw), fake.scheme == "http", fake.host == "127.0.0.1"
        {
            self.configuration = OneDriveConfiguration(
                clientID: "porpoise-onedrive-fixture", authorizationURL: fake.appendingPathComponent("auth"),
                tokenURL: fake.appendingPathComponent("token"), graphURL: fake.appendingPathComponent("v1.0"), pollInterval: 2)
        } else {
            self.configuration = configuration
        }
        saved = records.load(); accounts = saved.map(\.account)
        status.onChange = { [weak self] in self?.onChange?() }
        for record in saved { install(record.account, configuration: config(clientID: record.clientID)) }
    }
    private func config(clientID: String? = nil) -> OneDriveConfiguration {
        var config = configuration ?? .selected(defaults: defaults); if let clientID { config.clientID = clientID }; return config
    }
    private func install(_ account: OneDriveAccount, configuration: OneDriveConfiguration, session: CloudOAuthSession? = nil) {
        let tokens = session ?? OneDriveTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
        let client = OneDriveClient(
            accountID: account.id, configuration: configuration, tokens: tokens, driveID: account.driveID,
            directory: directory.appendingPathComponent(account.id.uuidString), http: http)
        client.onReachability = { [weak self] error in
            Task { @MainActor in self?.status.record(account.id, error, signInNeeded: (error as? OneDriveError) == .reconnect) }
        }
        clients[account.id] = client
        status.track(account.id)
    }
    public func client(for id: UUID) -> OneDriveClient? { clients[id] }
    public func connect(expected: OneDriveAccount? = nil, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> OneDriveAccount {
        let configuration = config(clientID: expected.flatMap { account in saved.first { $0.account.id == account.id }?.clientID })
        return try await signIn.run(listener: { try CloudOAuthLoopback() }, email: \.email) { listener in
            let transaction = try OneDriveOAuthTransaction(configuration: configuration, redirectURL: listener.redirectURL)
            openBrowser(transaction.authorizationURL)
            let callback = try await listener.callback()
            let token = try await transaction.exchange(callback, http: http)
            try Task.checkCancellation()
            // The short-lived access token identifies the person and their drive before any refresh credential is kept.
            func read<T: Decodable>(_ path: String) async throws -> T {
                var request = URLRequest(url: configuration.graphURL.appendingPathComponent(path))
                request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
                let (bytes, response) = try await http.response(request); try OneDriveClient.check(bytes, response)
                return try JSONDecoder().decode(T.self, from: bytes)
            }
            struct Me: Decodable { var id: String; var displayName: String?; var mail: String?; var userPrincipalName: String? }
            struct Drive: Decodable { var id: String; var driveType: String? }
            let me: Me = try await read("me"), drive: Drive = try await read("me/drive")
            guard !me.id.isEmpty, !drive.id.isEmpty, let email = me.mail ?? me.userPrincipalName, !email.isEmpty else {
                throw OneDriveError.invalidResponse
            }
            try CloudSignIn.check(
                expected: expected?.id, isExpected: expected?.userID == me.id, existing: accounts.first { $0.userID == me.id }?.id)
            let account = OneDriveAccount(
                id: expected?.id ?? UUID(), userID: me.id, email: email, displayName: me.displayName ?? email, driveID: drive.id,
                driveType: drive.driveType ?? "personal")
            let existingRefresh = try credentials.read(clientID: configuration.clientID, accountID: account.id)
            guard token.refresh_token?.isEmpty == false || existingRefresh != nil else { throw OneDriveError.reconnect }
            if let old = clients[account.id] {
                await old.changes.stop(); _ = try await old.tokens.disconnect()
                if token.refresh_token == nil, let existingRefresh {
                    try credentials.save(existingRefresh, clientID: configuration.clientID, accountID: account.id)
                }
            }
            let tokens = OneDriveTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
            try await tokens.accept(token)
            install(account, configuration: configuration, session: tokens)
            saved.removeAll { $0.account.id == account.id }; saved.append(.init(account: account, clientID: configuration.clientID))
            try persist()
            return account
        }
    }
    /// Microsoft has no revocation of one refresh token for a public client (revokeSignInSessions would sign the person
    /// out everywhere): signing out forgets every credential here, and the sign-in lapses at Microsoft unused.
    public func disconnect(_ id: UUID) async throws {
        guard let client = clients[id] else { return }
        guard await client.edits.pending().isEmpty else { throw CloudConnectionError.unsentEdits }
        let owned = directory.appendingPathComponent(id.uuidString)
        let drives = (try? FileManager.default.contentsOfDirectory(at: owned, includingPropertiesForKeys: nil)) ?? []
        // Other drives' clients (shared items) share the credential but keep their own edit and journal folders.
        for drive in drives {
            let edits = drive.appendingPathComponent("Edits")
            for path in (try? FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil)) ?? []
            where path.pathExtension == "json" {
                guard let bytes = try? Data(contentsOf: path), let edit = try? JSONDecoder().decode(OneDriveEditStore.Session.self, from: bytes),
                    edit.localURL.standardizedFileURL.path.hasPrefix(owned.standardizedFileURL.path + "/"),
                    (try? OneDriveContentHash.hash(edit.localURL)) == edit.sentHash
                else { throw CloudConnectionError.unsentEdits }
            }
        }
        await CloudTransferJournal.stop(account: "onedrive:" + id.uuidString.lowercased())
        await client.changes.stop()
        let source = client.contentSource
        _ = try await client.offlineCopies()
        try await CloudAccountWipe.offlineCopies(source.accountID)
        _ = try await client.tokens.disconnect()
        for drive in drives {
            let journal = CloudJournal<OneDriveOperation>(folder: drive.appendingPathComponent("Operations"))
            for record in try journal.all() where record.hasSession { try await client.tokens.removeSecret(record.operationID) }
        }
        try CloudAccountWipe.transfers("onedrive:" + id.uuidString.lowercased())
        try CloudAccountWipe.remove(owned)
        clients[id] = nil; status.forget(id); saved.removeAll { $0.account.id == id }; try persist()
    }
    private func persist() throws {
        try records.save(saved); accounts = saved.map(\.account); onChange?()
    }
}
