import Foundation
import PorpoiseCore

/// Box accounts: loopback sign-in, the same person checks, refresh credentials, persisted account metadata, reconnect
/// and disconnect.
@MainActor public final class BoxAccountStore {
    public static let shared = BoxAccountStore(directory: defaultDirectory)
    static var defaultDirectory: URL {
        if CredentialStores.isIsolated, !Settings.isTesting {
            let suite = TestEnvironment.defaultsSuite.value() ?? "tests"
            return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-box-" + cloudObjectKey(suite))
        }
        return Settings.supportFolder.appendingPathComponent("Box")
    }
    public private(set) var accounts: [BoxAccount] = []
    /// OK, offline or waiting to be signed in again, per account.
    public let status = CloudAccountStatus()
    private let signIn = CloudSignIn(provider: "Box")
    public var connecting: Bool { signIn.inProgress }
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let credentials: any CloudCredentialStore
    private let configuration: BoxConfiguration?
    private let http: CloudHTTPTransport
    private let directory: URL
    private let records: CloudAccountRecords<BoxAccount>
    private var saved: [CloudAccountRecords<BoxAccount>.Record] = []
    private var clients: [UUID: BoxClient] = [:]
    public init(
        defaults: UserDefaults = Settings.store, credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "box"),
        configuration: BoxConfiguration? = nil, directory: URL, http: CloudHTTPTransport = .init()
    ) {
        self.defaults = defaults; self.credentials = credentials; self.directory = directory; self.http = http
        records = CloudAccountRecords(defaults: defaults, key: "boxAccounts", clientField: "clientID")
        if configuration == nil, Settings.isTesting, let raw = TestEnvironment.boxFake.value(), let fake = URL(string: raw), fake.scheme == "http",
            fake.host == "127.0.0.1"
        {
            self.configuration = BoxConfiguration(
                clientID: "porpoise-box-fixture", clientSecret: "porpoise-box-fixture-secret", authorizationURL: fake.appendingPathComponent("auth"),
                tokenURL: fake.appendingPathComponent("oauth2/token"), revokeURL: fake.appendingPathComponent("oauth2/revoke"),
                apiURL: fake.appendingPathComponent("2.0"), uploadURL: fake.appendingPathComponent("upload/2.0"), longPollTimeout: 5)
        } else {
            self.configuration = configuration
        }
        saved = records.load(); accounts = saved.map(\.account)
        status.onChange = { [weak self] in self?.onChange?() }
        for record in saved { install(record.account, configuration: config(clientID: record.clientID)) }
    }
    /// The configuration in use; an account keeps the application it signed in with.
    private func config(clientID: String? = nil) -> BoxConfiguration {
        var config = configuration ?? .selected(defaults: defaults)
        if let clientID, clientID != config.clientID { config.clientID = clientID }
        return config
    }
    private func install(_ account: BoxAccount, configuration: BoxConfiguration, session: CloudOAuthSession? = nil) {
        let tokens = session ?? BoxTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
        let client = BoxClient(
            accountID: account.id, configuration: configuration, tokens: tokens, directory: directory.appendingPathComponent(account.id.uuidString),
            http: http)
        client.onReachability = { [weak self] error in
            Task { @MainActor in self?.status.record(account.id, error, signInNeeded: (error as? BoxError) == .reconnect) }
        }
        clients[account.id] = client
        status.track(account.id)
    }
    public func client(for id: UUID) -> BoxClient? { clients[id] }
    public func connect(expected: BoxAccount? = nil, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> BoxAccount {
        let configuration = config(clientID: expected.flatMap { account in saved.first { $0.account.id == account.id }?.clientID })
        return try await signIn.run(listener: { try CloudOAuthLoopback() }, email: \.email) { listener in
            let transaction = try BoxOAuthTransaction(configuration: configuration, redirectURL: listener.redirectURL)
            openBrowser(transaction.authorizationURL)
            let callback = try await listener.callback()
            let token = try await transaction.exchange(callback, http: http)
            try Task.checkCancellation()
            // The short-lived access token identifies the person before any refresh credential is kept.
            var request = URLRequest(url: configuration.apiURL.appendingPathComponent("users/me"))
            request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await http.response(request); try BoxClient.check(bytes, response)
            struct Me: Decodable { var id: String; var name: String?; var login: String? }
            let me = try JSONDecoder().decode(Me.self, from: bytes)
            guard !me.id.isEmpty, let email = me.login, !email.isEmpty else { throw BoxError.invalidResponse }
            try CloudSignIn.check(expected: expected?.id, isExpected: expected?.userID == me.id, existing: accounts.first { $0.userID == me.id }?.id)
            let account = BoxAccount(id: expected?.id ?? UUID(), userID: me.id, email: email, displayName: me.name ?? email)
            let existingRefresh = try credentials.read(clientID: configuration.clientID, accountID: account.id)
            guard token.refresh_token?.isEmpty == false || existingRefresh != nil else { throw BoxError.reconnect }
            if let old = clients[account.id] {
                await old.changes.stop(); _ = try await old.tokens.disconnect()
                if token.refresh_token == nil, let existingRefresh {
                    try credentials.save(existingRefresh, clientID: configuration.clientID, accountID: account.id)
                }
            }
            let tokens = BoxTokens.session(configuration: configuration, accountID: account.id, credentials: credentials, http: http)
            try await tokens.accept(token)
            install(account, configuration: configuration, session: tokens)
            saved.removeAll { $0.account.id == account.id }; saved.append(.init(account: account, clientID: configuration.clientID))
            try persist()
            return account
        }
    }
    /// Signing out revokes the sign-in at Box (best effort) and forgets every credential and copy here.
    public func disconnect(_ id: UUID) async throws {
        guard let client = clients[id] else { return }
        guard await client.edits.pending().isEmpty else { throw CloudConnectionError.unsentEdits }
        let owned = directory.appendingPathComponent(id.uuidString)
        let edits = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
        for path in (try? FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil)) ?? []
        where path.pathExtension == "json" {
            guard let bytes = try? Data(contentsOf: path), let edit = try? JSONDecoder().decode(BoxEditStore.Session.self, from: bytes),
                edit.localURL.standardizedFileURL.path.hasPrefix(owned.standardizedFileURL.path + "/"),
                (try? BoxContentHash.hash(edit.localURL)) == edit.sentHash
            else { throw CloudConnectionError.unsentEdits }
        }
        await CloudTransferJournal.stop(account: "box:" + id.uuidString.lowercased())
        await client.changes.stop()
        let source = client.contentSource
        _ = try await client.offlineCopies()
        try await CloudAccountWipe.offlineCopies(source.accountID)
        if let refresh = try await client.tokens.disconnect() { await BoxTokens.revoke(refresh, configuration: client.configuration, http: http) }
        for record in try client.journal.all() where record.hasSession { try await client.tokens.removeSecret(record.operationID) }
        try CloudAccountWipe.transfers("box:" + id.uuidString.lowercased())
        try CloudAccountWipe.remove(owned)
        clients[id] = nil; status.forget(id); saved.removeAll { $0.account.id == id }; try persist()
    }
    private func persist() throws {
        try records.save(saved); accounts = saved.map(\.account); onChange?()
    }
}
