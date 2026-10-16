import Combine
import Foundation
import PorpoiseCore

public enum DriveAccountState: String, Sendable { case connected, offline, needsSignIn }

public enum DriveConnectionError: LocalizedError, Equatable {
    case alreadyConnected(DriveAccount)
    case wrongAccount
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected(let account): return "\(account.email) is already connected."
        case .wrongAccount: return "Choose the same Google account to reconnect this Place."
        }
    }
}

/// Main-thread account metadata and lifecycle. Credentials never enter UserDefaults or notifications.
@MainActor
public final class DriveAccountStore: ObservableObject {
    public static let shared = DriveAccountStore()
    public static let changed = Notification.Name("PorpoiseDriveAccountsChanged")
    @Published public private(set) var accounts: [DriveAccount] = []
    @Published public private(set) var states: [UUID: DriveAccountState] = [:]
    @Published public private(set) var connecting = false
    @Published public private(set) var lastError: String?
    private struct Saved: Codable { var account: DriveAccount; var clientID: String }
    private struct Profile: Decodable { var sub: String; var email: String; var name: String?; var picture: URL? }
    private let defaults: UserDefaults
    private let credentials: any DriveCredentialStore
    private let http: DriveHTTP
    private let configuration: DriveOAuthConfiguration?
    private let baseURL: URL
    private var saved: [Saved] = []
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
        if configuration == nil, Settings.isTesting,
            let raw = ProcessInfo.processInfo.environment["PORPOISE_DRIVE_FAKE"], let fake = URL(string: raw),
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
        if let data = defaults.data(forKey: "googleDriveAccounts"), let stored = try? JSONDecoder().decode([Saved].self, from: data) {
            saved = stored
            accounts = stored.map(\.account)
            for record in stored { install(record.account, config: config(clientID: record.clientID)) }
        }
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
        let env = ProcessInfo.processInfo.environment
        let selected =
            clientID ?? env["PORPOISE_GOOGLE_CLIENT_ID"] ?? (clientIDOverride.isEmpty ? nil : clientIDOverride)
            ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientID") as? String) ?? ""
        return DriveOAuthConfiguration(
            clientID: selected,
            clientSecret: env["PORPOISE_GOOGLE_CLIENT_SECRET"] ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientSecret") as? String))
    }

    private func install(_ account: DriveAccount, config: DriveOAuthConfiguration, authenticated: DriveTokenManager? = nil) {
        let manager = authenticated ?? DriveTokenManager(configuration: config, accountID: account.id, credentials: credentials, http: http)
        (RemoteFS.provider(for: DriveLocation(accountID: account.id).url) as? DriveProvider)?.invalidate()
        let client = DriveClient(accountID: account.id, tokens: manager, http: http, baseURL: baseURL) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.clients[account.id] != nil else { return }
                if let error {
                    if (error as? DriveError) == .reconnect {
                        self.states[account.id] = .needsSignIn
                    } else if error is URLError {
                        self.states[account.id] = .offline
                    }
                } else {
                    self.states[account.id] = .connected
                }
            }
        }
        states[account.id] = .connected
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
        defaults.set(try JSONEncoder().encode(saved), forKey: "googleDriveAccounts")
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
        guard !connecting else { throw DriveError.oauthCancelled }
        connecting = true; lastError = nil
        defer { connecting = false }
        do {
            let config = config(clientID: expected.flatMap { account in saved.first { $0.account.id == account.id }?.clientID })
            guard !config.clientID.isEmpty else { throw DriveError.configuration }
            let listener = try DriveLoopback()
            defer { listener.cancel() }
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
            if let expected, expected.subject != profile.sub { throw DriveConnectionError.wrongAccount }
            if expected == nil, let existing { throw DriveConnectionError.alreadyConnected(existing.account) }
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
            saved.append(Saved(account: account, clientID: config.clientID))
            try persist()
            return account
        } catch {
            lastError = error is CancellationError ? DriveError.oauthCancelled.localizedDescription : error.localizedDescription
            throw error
        }
    }

    public func disconnect(_ account: DriveAccount) async throws {
        guard let manager = managers[account.id] else { return }
        var failure: Error?
        do { try await manager.revoke() } catch let error as DriveError {
            if case .keychain = error { lastError = error.localizedDescription; throw error }
            failure = error
        } catch { failure = error }
        (RemoteFS.provider(for: DriveLocation(accountID: account.id).url) as? DriveProvider)?.invalidate()
        await clients[account.id]?.clearCaches()
        managers[account.id] = nil; clients[account.id] = nil; states[account.id] = nil
        RemoteFS.unregisterDrive(accountID: account.id)
        saved.removeAll { $0.account.id == account.id }
        try persist()
        if let failure { lastError = failure.localizedDescription; throw failure }
        lastError = nil
    }
}
