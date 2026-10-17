import Foundation
import PorpoiseCore

/// Engine-only account lifecycle. UI registration/Connect sheet availability is a separate integration step.
@MainActor public final class DropboxAccountStore {
    public static let shared = DropboxAccountStore(directory: defaultDirectory)
    static var defaultDirectory: URL {
        if CredentialStores.isIsolated, !Settings.isTesting {
            let suite = ProcessInfo.processInfo.environment["PORPOISE_DEFAULTS_SUITE"] ?? "tests"
            return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-dropbox-" + cloudObjectKey(suite))
        }
        return Settings.supportFolder.appendingPathComponent("Dropbox")
    }
    public private(set) var accounts: [DropboxAccount] = []
    /// OK, offline or waiting to be signed in again, per account.
    public let status = CloudAccountStatus()
    private let signIn = CloudSignIn(provider: "Dropbox")
    public var connecting: Bool { signIn.inProgress }
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let credentials: any CloudCredentialStore
    private let configuration: DropboxConfiguration?
    private let http: CloudHTTPTransport
    private let directory: URL
    private let records: CloudAccountRecords<DropboxAccount>
    private var saved: [CloudAccountRecords<DropboxAccount>.Record] = []
    private var clients: [UUID: DropboxClient] = [:]
    public init(
        defaults: UserDefaults = Settings.store, credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "dropbox"),
        configuration: DropboxConfiguration? = nil, directory: URL, http: CloudHTTPTransport = .init()
    ) {
        self.defaults = defaults; self.credentials = credentials; self.directory = directory; self.http = http
        records = CloudAccountRecords(defaults: defaults, key: "dropboxAccounts", clientField: "appKey")
        if configuration == nil, Settings.isTesting, let raw = ProcessInfo.processInfo.environment["PORPOISE_DROPBOX_FAKE"],
            let fake = URL(string: raw), fake.scheme == "http", fake.host == "127.0.0.1"
        {
            self.configuration = DropboxConfiguration(
                appKey: "porpoise-dropbox-fixture", loopbackPort: 0, authorizationURL: fake.appendingPathComponent("auth"),
                tokenURL: fake.appendingPathComponent("token"), apiURL: fake.appendingPathComponent("2"),
                contentURL: fake.appendingPathComponent("2"), notifyURL: fake.appendingPathComponent("2"))
        } else {
            self.configuration = configuration
        }
        saved = records.load(); accounts = saved.map(\.account)
        status.onChange = { [weak self] in self?.onChange?() }
        for record in saved { install(record.account, configuration: config(appKey: record.clientID)) }
    }
    private func config(appKey: String? = nil) -> DropboxConfiguration {
        var config = configuration ?? .selected(defaults: defaults); if let appKey { config.appKey = appKey }; return config
    }
    private func install(_ account: DropboxAccount, configuration: DropboxConfiguration, session: CloudOAuthSession? = nil) {
        let tokens = session ?? DropboxTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
        let client = DropboxClient(
            accountID: account.id, configuration: configuration, tokens: tokens,
            namespaceID: account.rootNamespaceID, directory: directory.appendingPathComponent(account.id.uuidString), http: http)
        client.onReachability = { [weak self] error in
            Task { @MainActor in self?.status.record(account.id, error, signInNeeded: (error as? DropboxError) == .reconnect) }
        }
        clients[account.id] = client
        status.track(account.id)
    }
    public func client(for id: UUID) -> DropboxClient? { clients[id] }
    public func connect(expected: DropboxAccount? = nil, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DropboxAccount {
        let configuration = config(appKey: expected.flatMap { account in saved.first { $0.account.id == account.id }?.clientID })
        return try await signIn.run(listener: { try configuration.makeLoopbackListener() }, email: \.email) { listener in
            let transaction = try DropboxOAuthTransaction(configuration: configuration, redirectURL: listener.redirectURL)
            openBrowser(transaction.authorizationURL)
            let callback = try await listener.callback()
            let token = try await transaction.exchange(callback, http: http)
            try Task.checkCancellation()
            // Use the short-lived access token to identify the account before persisting any refresh credential.
            var request = URLRequest(url: configuration.apiURL.appendingPathComponent("users/get_current_account"))
            request.httpMethod = "POST"; request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = Data("null".utf8)
            let (bytes, response) = try await http.response(request); try DropboxClient.check(bytes, response)
            struct Profile: Decodable {
                struct Name: Decodable { var display_name: String }
                struct Root: Decodable { var root_namespace_id: String; var home_namespace_id: String }
                var account_id: String; var email: String; var name: Name; var root_info: Root
            }
            let profile = try JSONDecoder().decode(Profile.self, from: bytes)
            guard !profile.account_id.isEmpty, !profile.email.isEmpty, !profile.root_info.root_namespace_id.isEmpty else {
                throw DropboxError.invalidResponse
            }
            try CloudSignIn.check(
                expected: expected?.id, isExpected: expected?.accountID == profile.account_id,
                existing: accounts.first { $0.accountID == profile.account_id }?.id)
            let account = DropboxAccount(
                id: expected?.id ?? UUID(), accountID: profile.account_id, email: profile.email,
                displayName: profile.name.display_name, rootNamespaceID: profile.root_info.root_namespace_id,
                homeNamespaceID: profile.root_info.home_namespace_id)
            guard try token.refresh_token?.isEmpty == false || credentials.read(clientID: configuration.appKey, accountID: account.id) != nil else {
                throw DropboxError.reconnect
            }
            let existingRefresh = try credentials.read(clientID: configuration.appKey, accountID: account.id)
            if let old = clients[account.id] {
                await old.changes.stop(); _ = try await old.tokens.disconnect()
                if token.refresh_token == nil, let existingRefresh {
                    try credentials.save(existingRefresh, clientID: configuration.appKey, accountID: account.id)
                }
            }
            let tokens = DropboxTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
            try await tokens.accept(token)
            install(account, configuration: configuration, session: tokens)
            saved.removeAll { $0.account.id == account.id }; saved.append(.init(account: account, clientID: configuration.appKey)); try persist()
            return account
        }
    }
    /// A future CloudBackend forwards foreground/background lifecycle here; no UI availability is changed.
    public func setActive(_ active: Bool) async {
        for client in clients.values {
            if active { await client.changes.start() } else { await client.changes.stop() }
        }
    }
    public func checkForChanges(_ id: UUID? = nil) async throws {
        for (key, client) in clients where id == nil || id == key { try await client.changes.check() }
    }
    public func disconnect(_ id: UUID) async throws {
        guard let client = clients[id] else { return }
        guard await client.edits.pending().isEmpty else { throw CloudConnectionError.unsentEdits }
        let owned = directory.appendingPathComponent(id.uuidString)
        let namespaces = (try? FileManager.default.contentsOfDirectory(at: owned, includingPropertiesForKeys: nil)) ?? []
        // Namespace clients share the account credential but keep independent edit/journal directories.
        // Disconnect must protect dirty copies and remove session credentials in every namespace.
        for namespace in namespaces {
            let edits = namespace.appendingPathComponent("Edits")
            for path in (try? FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil)) ?? []
            where path.pathExtension == "json" {
                guard let bytes = try? Data(contentsOf: path), let edit = try? JSONDecoder().decode(DropboxEditStore.Session.self, from: bytes),
                    edit.localURL.standardizedFileURL.path.hasPrefix(owned.standardizedFileURL.path + "/"),
                    (try? DropboxContentHash.hash(edit.localURL)) == edit.sentHash
                else { throw CloudConnectionError.unsentEdits }
            }
        }
        await client.changes.stop()
        let source = client.contentSource
        _ = try await client.offlineCopies()
        try await CloudAccountWipe.offlineCopies(source.accountID)
        // An access token for Dropbox's revoke, read before the credentials are forgotten here.
        let access = try? await client.tokens.accessToken()
        _ = try await client.tokens.disconnect()
        // Not waited for: a slow or failed revoke never holds up or fails signing out here.
        if let access {
            Task.detached { [configuration = client.configuration, http] in
                await DropboxTokens.revoke(access, configuration: configuration, http: http)
            }
        }
        for namespace in namespaces {
            let journal = CloudJournal<DropboxOperation>(folder: namespace.appendingPathComponent("Operations"))
            for record in try journal.all() where record.hasSession { try await client.tokens.removeSecret(record.operationID) }
        }
        // Only this account's private engine data is removed. No provider is registered in the UI yet.
        try CloudAccountWipe.remove(owned)
        clients[id] = nil; status.forget(id); saved.removeAll { $0.account.id == id }; try persist()
    }
    private func persist() throws {
        try records.save(saved); accounts = saved.map(\.account); onChange?()
    }
}
