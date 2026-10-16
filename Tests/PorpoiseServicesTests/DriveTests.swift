import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

final class MemoryDriveCredentials: DriveCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(clientID: String, accountID: UUID) throws -> String? { lock.withLock { values["\(clientID)/\(accountID)"] } }
    func save(_ token: String, clientID: String, accountID: UUID) throws { lock.withLock { values["\(clientID)/\(accountID)"] = token } }
    func remove(clientID: String, accountID: UUID) throws { _ = lock.withLock { values.removeValue(forKey: "\(clientID)/\(accountID)") } }
}

/// Each test owns its local process and ephemeral port. No live account, real Keychain or external network.
final class FakeDriveServer {
    let process = Process()
    let scratch: Scratch
    let base: URL
    init(fixture: URL? = nil) throws {
        scratch = try Scratch()
        let portFile = scratch.url.appendingPathComponent("port")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repo.appendingPathComponent("scripts/fake-drive-server.py").path, "--port", "0", "--port-file", portFile.path]
        if let fixture { process.arguments! += ["--fixture", fixture.path] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline, process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        guard let port = try? String(contentsOf: portFile, encoding: .utf8), Int(port) != nil else {
            process.terminate(); throw DriveError.invalidResponse
        }
        base = URL(string: "http://127.0.0.1:\(port)")!
    }
    deinit { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    var config: DriveOAuthConfiguration {
        DriveOAuthConfiguration(
            clientID: "fixture-client", authorizationURL: base.appendingPathComponent("auth"), tokenURL: base.appendingPathComponent("token"),
            revokeURL: base.appendingPathComponent("revoke"), profileURL: base.appendingPathComponent("userinfo"))
    }
    func client(id: UUID = UUID(), refresh: String = "fixture-refresh") throws -> (DriveClient, DriveTokenManager, MemoryDriveCredentials) {
        let credentials = MemoryDriveCredentials()
        try credentials.save(refresh, clientID: config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: config, accountID: id, credentials: credentials)
        return (DriveClient(accountID: id, tokens: tokens, baseURL: base.appendingPathComponent("drive/v3/")), tokens, credentials)
    }
}

@Suite(.serialized) struct DriveTests {
    @Test func realHTTPPagingSharedCollectionsShortcutsAndExports() async throws {
        let server = try FakeDriveServer()
        let (client, _, _) = try server.client()
        let root = DriveLocation(accountID: client.accountID)
        let first = try await client.listPage(root)
        #expect(first.files.count == 2 && first.nextPageToken == "page-two")
        let files = try await client.list(root)
        #expect(files.count == 6)
        let duplicates = files.filter { $0.name == "report.txt" }
        #expect(duplicates.count == 2 && Set(duplicates.map(\.id)).count == 2)
        let shared = try await client.list(DriveLocation(accountID: client.accountID, collection: .sharedWithMe))
        #expect(shared.map(\.id) == ["folder-a", "doc-a", "shortcut-a"])
        let drives = try await client.list(DriveLocation(accountID: client.accountID, collection: .sharedDrives))
        #expect(drives.first?.driveId == "shared-drive-a")
        let children = try await client.list(
            DriveLocation(accountID: client.accountID, collection: .folder("shared-drive-a", driveID: "shared-drive-a")))
        #expect(children.count == 2)
        let shortcut = try await client.file("shortcut-a")
        let target = try await client.resolve(shortcut)
        #expect(target.id == "folder-a" && target.isFolder)
        #expect(try await client.list(shortcut.location(accountID: client.accountID)).count == 2)
        await #expect(throws: DriveError.shortcutCycle) { try await client.resolve(client.file("cycle-a")) }
        let doc = try await client.file("doc-a")
        #expect(doc.sharingUser?.displayName == "Sam Example" && doc.permissions?.count == 2)
        let exported = try await client.download(doc)
        #expect(exported.name == "Meeting notes.docx" && exported.data == Data("fixture bytes".utf8))
        #expect(try await client.download(doc, preset: .pdf).name == "Meeting notes.pdf")
        #expect(try await client.download(client.file("binary-a")).name == "report.txt")
        await #expect(throws: DriveError.permissionDenied) { try await client.download(client.file("denied")) }
        await #expect(throws: DriveError.unsupportedExport) { try await client.download(client.file("native-unsupported")) }
        await #expect(throws: DriveError.notFound) { try await client.file("missing") }
        await #expect(throws: DriveError.quota) { try await client.file("quota") }
        let info = try await client.accountInfo()
        #expect(info.storageUsed == 1024 && info.storageLimit == 16106127360 && info.hasSharedDrives)
        #expect(client.cachedFile(for: doc.location(accountID: client.accountID).url)?.name == doc.name)
        #expect(client.cachedFile(for: doc.location(accountID: UUID()).url) == nil)
        await #expect(throws: DriveError.invalidLocation) { try await client.list(DriveLocation(accountID: UUID())) }
    }

    @Test func providerUsesIDAncestryRefusesWritesAndStagesDownloads() async throws {
        let server = try FakeDriveServer()
        let (client, _, _) = try server.client()
        let root = DriveLocation(accountID: client.accountID)
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        #expect(RemoteFS.isRemote(root.url) && RemoteFS.provider(for: root.url) === provider)
        let rows = try provider.list(root.url)
        #expect(rows.count == 6 && rows.allSatisfy { !$0.isWritable })
        #expect(rows[0].url.deletingLastPathComponent() == root.url)
        #expect(RemoteFS.displayName(for: rows[0].url) == "Project Atlas")
        #expect(RemoteFS.displayName(for: root.url) == "My Drive")
        #expect(rows.first { $0.name == "Atlas shortcut" }?.isDirectory == true)
        let local = try Scratch()
        let binary = try #require(rows.first { $0.name == "report.txt" })
        let output = try provider.download(binary.url, into: local.url)
        #expect(try Data(contentsOf: output) == Data("fixture bytes".utf8))
        #expect(throws: (any Error).self) { try provider.download(binary.url, into: local.url) }
        #expect(throws: DriveError.readOnly) { try provider.upload(output, into: root.url) }
        #expect(throws: DriveError.readOnly) { try provider.delete([binary.url]) }
        #expect(throws: DriveError.readOnly) { try provider.makeFolder(root.url) }
        #expect(throws: DriveError.readOnly) { try provider.removeEmptyFolder(root.url) }
        #expect(throws: DriveError.readOnly) { try provider.rename(binary.url, to: "new") }
        #expect(throws: DriveError.readOnly) { try provider.move([binary.url], into: root.url) }
        #expect(throws: DriveError.readOnly) { try provider.copy([binary.url], into: root.url) }
        #expect(throws: DriveError.invalidLocation) { try provider.list(DriveLocation(accountID: UUID()).url) }
        let bad = try await client.file("bad-name")
        #expect(throws: (any Error).self) { try provider.download(bad.location(accountID: client.accountID).url, into: local.url) }
        let page = try await provider.listPage(root.url)
        #expect(page.items.count == 2)
        #expect(provider.metadata(for: binary.url)?.name == "report.txt")
        let disconnected = DriveProvider(accountID: UUID(), client: nil)
        #expect(throws: DriveError.reconnect) { try disconnected.list(DriveLocation(accountID: disconnected.accountID).url) }
        #expect(RemoteFS.provider(for: URL(string: "gdrive://invalid/my-drive")!) == nil)
    }

    @Test func revokedRefreshAndExplicitDisconnectForgetSecrets() async throws {
        let server = try FakeDriveServer()
        let (client, tokens, credentials) = try server.client(refresh: "revoked")
        await #expect(throws: DriveError.reconnect) { try await tokens.accessToken() }
        try credentials.save("fixture-refresh", clientID: server.config.clientID, accountID: client.accountID)
        #expect(try await tokens.accessToken() == "fixture-access")
        try await tokens.revoke()
        #expect(try credentials.read(clientID: server.config.clientID, accountID: client.accountID) == nil)
        await #expect(throws: DriveError.reconnect) { try await tokens.accessToken() }
    }

    @Test func PKCEStateCancellationAndTimeout() async throws {
        let listener = try DriveLoopback()
        let config = DriveOAuthConfiguration(clientID: "configured")
        let transaction = try DriveOAuthTransaction(configuration: config, redirectURL: listener.redirectURL)
        let query = URLComponents(url: transaction.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(transaction.verifier.count == 43 && transaction.state.count == 43)
        #expect(
            query.first { $0.name == "code_challenge" }?.value
                == DriveOAuthTransaction.base64URL(Data(SHA256.hash(data: Data(transaction.verifier.utf8)))))
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(!query.contains { $0.name == "login_hint" })
        let again = try DriveOAuthTransaction(configuration: config, redirectURL: listener.redirectURL, loginHint: "a@example.invalid")
        #expect(
            URLComponents(url: again.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "login_hint" }?.value
                == "a@example.invalid")
        let callback = URL(string: "\(listener.redirectURL)?state=\(transaction.state)&code=auth-code")!
        #expect(try transaction.code(from: callback) == "auth-code")
        #expect(throws: DriveError.oauthState) { try transaction.code(from: URL(string: "\(listener.redirectURL)?state=wrong&code=x")!) }
        #expect(throws: DriveError.oauthState) { try transaction.code(from: URL(string: "\(callback)&state=duplicate")!) }
        #expect(throws: DriveError.oauthCancelled) {
            try transaction.code(from: URL(string: "\(listener.redirectURL)?state=\(transaction.state)&error=access_denied")!)
        }
        #expect(throws: DriveError.invalidResponse) { try transaction.code(from: URL(string: "\(listener.redirectURL)?state=\(transaction.state)")!) }
        #expect(throws: DriveError.configuration) {
            try DriveOAuthTransaction(configuration: DriveOAuthConfiguration(clientID: " "), redirectURL: listener.redirectURL)
        }
        let receiving = Task { try await listener.callback() }
        _ = try await URLSession.shared.data(from: callback)
        #expect(try await receiving.value == callback)
        await #expect(throws: DriveError.oauthCancelled) { try await listener.callback() }
        let timeout = try DriveLoopback()
        await #expect(throws: DriveError.oauthTimeout) { try await timeout.callback(timeout: 0.01) }
        let cancel = try DriveLoopback()
        let waiting = Task { try await cancel.callback() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

@Suite(.serialized) struct DriveAccountTests {
    @MainActor @Test func browserOAuthPersistenceDuplicateReauthorizationAndRemoval() async throws {
        let server = try FakeDriveServer()
        let credentials = MemoryDriveCredentials()
        let suite = "porpoise-drive-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriveAccountStore(
            defaults: defaults, credentials: credentials, configuration: server.config, baseURL: server.base.appendingPathComponent("drive/v3/"))
        store.clientIDOverride = "  override-client  "
        #expect(store.clientIDOverride == "override-client")
        let browser: @MainActor (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let account = try await store.connect(openBrowser: browser)
        defer { RemoteFS.unregisterDrive(accountID: account.id) }
        #expect(account.email == "alex@example.invalid" && store.accounts == [account])
        #expect(store.states[account.id] == .connected && !store.connecting && store.lastError == nil)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == "fixture-refresh")
        let metadata = try #require(defaults.data(forKey: "googleDriveAccounts"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("fixture-refresh"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("fixture-access"))
        let restored = DriveAccountStore(
            defaults: defaults, credentials: credentials, configuration: server.config, baseURL: server.base.appendingPathComponent("drive/v3/"))
        #expect(restored.accounts == [account] && restored.client(for: account.id) != nil)
        await #expect(throws: DriveConnectionError.alreadyConnected(account)) { try await store.connect(openBrowser: browser) }
        #expect(store.accounts.count == 1)
        let reconnected = try await store.reauthorize(account, openBrowser: browser)
        #expect(reconnected.id == account.id)
        try await store.disconnect(account)
        #expect(store.accounts.isEmpty && store.client(for: account.id) == nil && store.states[account.id] == nil)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == nil)
        try await store.disconnect(account)
    }

    @MainActor @Test func customFixturesConnectTwoDistinctAccounts() async throws {
        let scratch = try Scratch()
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/metadata.json")
        var fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: original)) as? [String: Any])
        fixture["profiles"] = [
            ["sub": "one", "email": "one@example.invalid", "name": "One"],
            ["sub": "two", "email": "two@example.invalid", "name": "Two"],
        ]
        let file = scratch.url.appendingPathComponent("custom.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let server = try FakeDriveServer(fixture: file)
        let suite = "porpoise-drive-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryDriveCredentials()
        let store = DriveAccountStore(
            defaults: defaults, credentials: credentials, configuration: server.config, baseURL: server.base.appendingPathComponent("drive/v3/"))
        let browser: @MainActor (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let one = try await store.connect(openBrowser: browser)
        let two = try await store.connect(openBrowser: browser)
        defer { RemoteFS.unregisterDrive(accountID: one.id); RemoteFS.unregisterDrive(accountID: two.id) }
        #expect(one.id != two.id && one.email == "one@example.invalid" && two.email == "two@example.invalid")
        #expect(store.accounts.count == 2)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: two.id) == "fixture-refresh-1")
        let secondClient = try #require(store.client(for: two.id))
        #expect(try await secondClient.list(DriveLocation(accountID: two.id)).count == 6)
    }

    @MainActor @Test func missingConfigurationAndCancelledConnect() async throws {
        let suite = "porpoise-drive-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = DriveAccountStore(
            defaults: defaults, credentials: MemoryDriveCredentials(), configuration: DriveOAuthConfiguration(clientID: ""))
        await #expect(throws: DriveError.configuration) {
            try await missing.connect { _ in Issue.record("Browser must not open without configuration") }
        }
        #expect(missing.lastError != nil && !missing.connecting)
        let server = try FakeDriveServer()
        let store = DriveAccountStore(defaults: defaults, credentials: MemoryDriveCredentials(), configuration: server.config)
        let task = Task { @MainActor in try await store.connect { _ in } }
        for _ in 0..<100 where !store.connecting { await Task.yield() }
        await #expect(throws: DriveError.oauthCancelled) { try await store.connect { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!store.connecting && store.accounts.isEmpty)
    }
}

actor DriveRequestLog {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

struct DriveTransportTests {
    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    @Test func requestFlagsResourceKeysRefreshCoalescingAnd401Retry() async throws {
        let log = DriveRequestLog()
        let id = UUID()
        let credentials = MemoryDriveCredentials()
        try credentials.save("refresh", clientID: "client", accountID: id)
        let http = DriveHTTP { request in
            await log.append(request)
            if request.url!.path == "/token" {
                try await Task.sleep(for: .milliseconds(10))
                return reply(request, #"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return reply(request, "{}", status: 401) }
            if request.url!.path == "/drive/v3/files/folder" {
                return reply(request, #"{"id":"folder","name":"Folder","mimeType":"application/vnd.google-apps.folder","driveId":"shared-drive"}"#)
            }
            return reply(request, #"{"files":[],"nextPageToken":null}"#)
        }
        let config = DriveOAuthConfiguration(clientID: "client", tokenURL: URL(string: "http://127.0.0.1/token")!)
        let manager = DriveTokenManager(configuration: config, accountID: id, credentials: credentials, http: http)
        async let a = manager.accessToken()
        async let b = manager.accessToken()
        #expect(try await a == "fresh")
        #expect(try await b == "fresh")
        #expect(await log.requests.filter { $0.url!.path == "/token" }.count == 1)
        try await manager.accept(DriveTokenResponse(access_token: "old", expires_in: 3600, refresh_token: nil, token_type: "Bearer"))
        let client = DriveClient(accountID: id, tokens: manager, http: http, baseURL: URL(string: "http://127.0.0.1/drive/v3/")!)
        _ = try await client.listPage(
            DriveLocation(accountID: id, collection: .folder("folder", driveID: "shared-drive"), resourceKey: "resource-key"), pageToken: "next-page")
        let requests = await log.requests
        #expect(requests.filter { $0.url!.path == "/token" }.count == 2)
        let metadataRequest = try #require(requests.first { $0.url!.path == "/drive/v3/files/folder" })
        #expect(metadataRequest.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") == "folder/resource-key")
        let listing = try #require(requests.last { $0.url!.path == "/drive/v3/files" })
        let q = URLComponents(url: listing.url!, resolvingAgainstBaseURL: false)!.queryItems!
        for (key, value) in [
            ("corpora", "drive"), ("driveId", "shared-drive"), ("supportsAllDrives", "true"), ("includeItemsFromAllDrives", "true"),
            ("pageToken", "next-page"),
        ] {
            #expect(q.first { $0.name == key }?.value == value)
        }
        #expect(q.first { $0.name == "q" }?.value == "'folder' in parents and trashed = false")
        #expect(q.first { $0.name == "fields" }?.value?.contains("shortcutDetails") == true)
    }

    @Test func errorMappingMalformedPagesAndSecretFreeErrors() async throws {
        for (status, error) in [(401, DriveError.reconnect), (403, .permissionDenied), (404, .notFound), (429, .quota), (500, .http(500))] {
            #expect(throws: error) { try DriveHTTP.check(status) }
            #expect(!error.localizedDescription.isEmpty)
        }
        for error in [
            DriveError.configuration, .invalidResponse, .invalidLocation, .oauthCancelled, .oauthState, .oauthTimeout, .shortcutCycle, .readOnly,
            .unsupportedExport, .keychain(-1),
        ] {
            #expect(!error.localizedDescription.isEmpty)
        }
        let id = UUID(), credentials = MemoryDriveCredentials()
        let manager = DriveTokenManager(configuration: DriveOAuthConfiguration(clientID: "test"), accountID: id, credentials: credentials)
        try await manager.accept(DriveTokenResponse(access_token: "access", expires_in: 3600, refresh_token: nil, token_type: "Bearer"))
        for body in [
            "not-json", #"{"files":[],"incompleteSearch":true}"#, #"{"files":[{"id":"unsafe/id","name":"x","mimeType":"text/plain"}]}"#,
            #"{"files":[],"nextPageToken":"repeated"}"#,
        ] {
            let http = DriveHTTP { request in reply(request, body) }
            let client = DriveClient(accountID: id, tokens: manager, http: http)
            await #expect(throws: DriveError.invalidResponse) { try await client.list(DriveLocation(accountID: id)) }
        }
        await #expect(throws: DriveError.invalidLocation) { try await DriveClient(accountID: id, tokens: manager).file("../bad") }
        await #expect(throws: DriveError.invalidResponse) {
            try await manager.accept(DriveTokenResponse(access_token: "", expires_in: 0, refresh_token: nil, token_type: "MAC"))
        }
        #expect(String(data: DriveHTTP.form(["a+b": "x &=y"]), encoding: .utf8) == "a%2Bb=x%20%26%3Dy")
    }
}

@MainActor @Suite(.isolatedSettings) struct DriveDirectoryTests {
    @Test func publishesPagesAndCancelsStaleNavigation() async throws {
        let id = UUID()
        let credentials = MemoryDriveCredentials()
        let tokens = DriveTokenManager(configuration: DriveOAuthConfiguration(clientID: "test"), accountID: id, credentials: credentials)
        try await tokens.accept(DriveTokenResponse(access_token: "access", expires_in: 3600, refresh_token: nil, token_type: "Bearer"))
        let log = DriveRequestLog()
        let http = DriveHTTP { request in
            await log.append(request)
            let paged = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "pageToken" }
            if paged { try await Task.sleep(for: .seconds(1)) }
            let body =
                paged
                ? #"{"files":[{"id":"late","name":"Late","mimeType":"text/plain"}]}"#
                : #"{"files":[{"id":"first","name":"First","mimeType":"text/plain"}],"nextPageToken":"next"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = DriveClient(accountID: id, tokens: tokens, http: http)
        let provider = DriveProvider(accountID: id, client: client)
        RemoteFS.registerDrive(provider, accountID: id)
        defer { RemoteFS.unregisterDrive(accountID: id) }
        let root = DriveLocation(accountID: id).url
        let model = DirectoryModel(location: root)
        model.reload()
        try #require(await eventually { model.items.map(\.name) == ["First"] && model.isLoading })
        let local = try Scratch()
        try Data().write(to: local.url.appendingPathComponent("Local"))
        model.setLocation(local.url)
        try #require(await eventually { !model.isLoading && model.items.map(\.name) == ["Local"] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.location == local.url && model.items.map(\.name) == ["Local"])
        model.setLocation(root)
        try #require(await eventually { !model.isLoading && model.items.count == 2 })
        #expect(model.loadError == nil)
        RemoteFS.unregisterDrive(accountID: id)
        model.reload()
        try #require(await eventually { !model.isLoading })
        #expect(model.loadError == DriveError.reconnect.localizedDescription)
    }
}

struct DriveKeychainTests {
    @Test func refreshCredentialsArePartitionedByClientAndAccount() throws {
        let test = try TestKeychain()
        let credentials = DriveKeychainCredentials(in: test.keychain)
        let account = UUID(), other = UUID()
        #expect(try credentials.read(clientID: "client-one", accountID: account) == nil)
        try credentials.save("first", clientID: "client-one", accountID: account)
        try credentials.save("second", clientID: "client-two", accountID: account)
        try credentials.save("third", clientID: "client-one", accountID: other)
        #expect(try credentials.read(clientID: "client-one", accountID: account) == "first")
        #expect(try credentials.read(clientID: "client-two", accountID: account) == "second")
        try credentials.save("updated", clientID: "client-one", accountID: account)
        #expect(try credentials.read(clientID: "client-one", accountID: account) == "updated")
        try credentials.remove(clientID: "client-one", accountID: account)
        try credentials.remove(clientID: "client-one", accountID: account)
        #expect(try credentials.read(clientID: "client-one", accountID: account) == nil)
        #expect(try credentials.read(clientID: "client-one", accountID: other) == "third")
        #expect(try credentials.read(clientID: "client-two", accountID: account) == "second")
    }
}
