import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DropboxTests {
    @Test func opaqueLocationsHeaderEncodingAndContentHashVectors() throws {
        let id = UUID()
        let location = DropboxLocation(accountID: id, itemID: "id:opaque/slash+%=😀", namespaceID: "ns+opaque/=")
        #expect(DropboxLocation(url: location.url) == location)
        for raw in ["dropbox://invalid/", "dropbox://\(id)/a/b", "dropbox://\(id)/a?bad=x", "dropbox://user@\(id)/", "dropbox://\(id)/a#fragment"] {
            #expect(DropboxLocation(url: URL(string: raw)!) == nil)
        }
        for parent in ["/../outside", "/a/./b", "/a\\b", "/a\0b"] {
            #expect(throws: DropboxError.invalidLocation) { try DropboxClient.childPath(name: "safe", parent: parent) }
        }
        let header = try dropboxHeader(["path": "/café/😀\u{7f}"])
        #expect(header.utf8.allSatisfy { $0 < 127 })
        let decoded = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        #expect(decoded?["path"] == "/café/😀\u{7f}")
        let scratch = try Scratch(); let empty = scratch.url.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try DropboxContentHash.hash(empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let bytes = Data(repeating: 97, count: (4 << 20) + 17); try bytes.write(to: empty)
        var outer = SHA256(); outer.update(data: Data(SHA256.hash(data: bytes.prefix(4 << 20))))
        outer.update(data: Data(SHA256.hash(data: bytes.suffix(17))))
        let expected = outer.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(try DropboxContentHash.hash(empty) == expected)
        #expect(try CloudChecksum.dropbox(expected).verify(empty))
        #expect(try !CloudChecksum.dropbox(String(repeating: "0", count: 64)).verify(empty))
        for name in ["..", ".", "a/b", "a\\b", "", "\0"] {
            #expect(throws: DropboxError.invalidLocation) { try DropboxClient.childPath(name: name, parent: "") }
        }
    }

    @Test func pagingSharedSearchNamespacesRefreshAndSnapshots() async throws {
        let server = try FakeDropboxServer(); let client = try server.client(namespace: "team-root")
        let first = try await client.listPage(); #expect(first.hasMore && first.cursor.contains("+cursor/="))
        let items = try await client.list(); #expect(items.count == 3)
        #expect(client.metadataCache.snapshot("")?.files.count == 3)
        let nested = try await client.list("id:folder"); #expect(nested.map(\.id) == ["id:nested"])
        let shared = try await client.sharedWithMe(); #expect(shared.contains { $0.id == "ns:unmounted:fixture" })
        let unmounted = try #require(shared.first { $0.id.hasPrefix("ns:") })
        let sharedClient = try client.sharedFolderClient(unmounted)
        #expect(sharedClient.namespaceID == "unmounted:fixture")
        #expect(sharedClient.contentSource.accountID != client.contentSource.accountID)
        _ = try await sharedClient.list()
        #expect(throws: DropboxError.invalidLocation) { try client.sharedFolderClient(items.first { !$0.isFolder }!) }
        let a = try await client.search("txt", contents: false); #expect(a.items.count == 2 && a.cursor != nil)
        let b = try await client.search("ignored", cursor: a.cursor); #expect(b.items.count == 1 && b.cursor == nil)
        try await server.configure(["rejectAuthOnce": true]); _ = try await client.metadata("id:hello")
        await #expect(throws: DropboxError.notFound) { try await client.metadata("id:missing") }
        let requests = try await server.requests()
        #expect(requests.allSatisfy { $0["namespace"] as? String != nil })
        #expect((try await server.stats())["tokens"] as? Int == 2)
        let restored = DropboxClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens,
            namespaceID: "team-root", directory: server.directory)
        #expect(restored.metadataCache.snapshot("")?.files.count == 3)
        #expect(restored.metadataCache.cursor("listing:") == client.metadataCache.cursor("listing:"))
        let item = try await client.metadata("id:hello"); #expect(item.fileItem(accountID: client.accountID).name == "hello.txt")
    }

    @Test func changesApplyOpaqueCursorDeletesNestedItemsAndReset() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        _ = try await client.list(); _ = try await client.list("id:folder")
        let source = client.contentSource
        let batch = BatchBox(); source.onChanges = { batch.add($0) }
        try await client.changes.check()
        let initialCursor = try #require(client.metadataCache.cursor("changes"))
        try await server.configure(["files": [["id": "id:new", "path": "/Folder/new.txt", "text": "new"]], "remove": ["/hello.txt"]])
        #expect(try await client.changes.pollOnce())
        #expect(client.metadataCache.file("id:hello") == nil)
        #expect(client.metadataCache.snapshot("id:folder")?.files.contains { $0.id == "id:new" } == true)
        #expect(batch.values.contains { $0.removed.contains("id:hello") })
        #expect(client.metadataCache.cursor("changes") != initialCursor)
        #expect(try await !client.changes.pollOnce())
        client.metadataCache.setCursor("expired", scope: "changes")
        try await client.changes.check(); #expect(batch.values.contains { $0.reset })
        client.metadataCache.setCursor("expired-longpoll", scope: "changes")
        #expect(try await client.changes.pollOnce())
        try await server.configure(["remove": ["/Folder", "/Folder/nested.txt", "/Folder/new.txt"]])
        try await client.changes.check(); #expect(client.metadataCache.file("id:nested") == nil)
        let polls = try await server.requests().filter { $0["route"] as? String == "files/list_folder/longpoll" }
        #expect(polls.allSatisfy { $0["auth"] as? Bool == false && ($0["namespace"] == nil || $0["namespace"] is NSNull) })
        await client.changes.start(); await client.changes.start(); await client.changes.stop()
    }

    @Test func conditionalMutationsConflictAndUncertainNeverReplay() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let id = UUID(); let folder = try await client.createFolder(name: "café😀", operationID: id)
        #expect(try await client.createFolder(name: "café😀", operationID: id) == folder)
        await #expect(throws: DropboxError.conflict) { try await client.createFolder(name: "café😀") }
        let file = try await client.metadata("id:hello")
        let renamed = try await client.rename(file, to: "renamed.txt"); #expect(renamed.id == file.id)
        let copied = try await client.copy(renamed, to: "/Folder/copy.txt"); #expect(copied.id != file.id)
        let moved = try await client.move(copied, to: "/moved.txt"); #expect(moved.id == copied.id)
        var stale = moved; stale.rev = "stale"
        await #expect(throws: DropboxError.conflict) { try await client.delete(stale) }
        let deleted = try await client.delete(moved)
        await #expect(throws: DropboxError.unsupportedUndo) { try await client.restore(deleted) }
        #expect(try await client.restore(deleted, confirmedMayReplace: true).id == moved.id)
        await #expect(throws: DropboxError.unsupportedUndo) { try await client.delete(folder) }
        _ = try await client.delete(folder, confirmedWithoutUndo: true)
        try await server.configure(["loseMutation": true])
        let uncertain = UUID()
        await #expect(throws: (any Error).self) { try await client.createFolder(name: "applied", operationID: uncertain) }
        await #expect(throws: DropboxError.uncertain) { try await client.createFolder(name: "applied", operationID: uncertain) }
        #expect(try await client.metadata("/applied").isFolder)
        await #expect(throws: DropboxError.sourceChanged) { try await client.createFolder(name: "different", operationID: id) }
        await #expect(throws: DropboxError.invalidLocation) { try await client.move(file, to: "/../bad") }
    }

    @Test func uploadSessionsLostAppendResumeConditionalSaveAndSecretRedaction() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let local = server.fixture.scratch.url.appendingPathComponent("input.bin")
        try Data(repeating: 39, count: (8 << 20) + 19).write(to: local)
        let operation = UUID(); try await server.configure(["loseAppend": true])
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "/résumé😀.bin", operationID: operation) }
        let pending = try #require(try client.journal.load(operation)); #expect(pending.phase == "appending" && pending.hasSession)
        let raw = try String(contentsOf: client.journal.folder.appendingPathComponent(operation.uuidString + ".json"), encoding: .utf8)
        #expect(!raw.contains("fixture-session:") && !raw.contains("fixture-refresh"))
        let result = try await client.upload(local, to: "/résumé😀.bin", operationID: operation)
        let localHash = try DropboxContentHash.hash(local)
        #expect(result.size == (8 << 20) + 19 && result.contentHash == localHash)
        #expect(try await client.tokens.secret(operation) == nil)
        #expect(try await client.upload(local, to: "/résumé😀.bin", operationID: operation) == result)
        let fresh = try await client.upload(local, to: "/résumé😀.bin", expectedRevision: result.rev)
        #expect(fresh.id == result.id && fresh.rev != result.rev)
        await #expect(throws: DropboxError.conflict) { try await client.upload(local, to: "/résumé😀.bin", expectedRevision: result.rev) }
        let requests = try await server.requests()
        #expect(requests.allSatisfy { $0["asciiArg"] as? Bool == true })
        let commits = requests.compactMap { $0["commit"] as? [String: Any] }
        #expect(commits.allSatisfy { $0["autorename"] as? Bool == false && $0["strict_conflict"] as? Bool == true })
        #expect(requests.contains { $0["route"] as? String == "files/upload_session/append_v2" && $0["bodyBytes"] as? Int == 8 << 20 })
        try await server.configure(["loseFinish": true]); let lost = UUID()
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "/uncertain.bin", operationID: lost) }
        await #expect(throws: DropboxError.uncertain) { try await client.upload(local, to: "/uncertain.bin", operationID: lost) }
        await #expect(throws: DropboxError.invalidLocation) { try await client.upload(server.fixture.scratch.url, to: "/folder") }
    }

    @Test func rangedDownloadIntegrityResumeSingleAndParallelNumbers() async throws {
        let server = try FakeDropboxServer(connectionMbps: 128, bandwidthMbps: 512)
        let client = try server.client()
        try await server.configure([
            "files": [["id": "id:large", "path": "/large.bin", "size": 32 << 20], ["id": "id:empty", "path": "/empty", "size": 0]]
        ])
        let file = try await client.metadata("id:large")
        let start = Date(); let single = try await client.download(file, maximumConnections: 1); let singleTime = Date().timeIntervalSince(start)
        let parallelStart = Date(); let parallel = try await client.download(file); let parallelTime = Date().timeIntervalSince(parallelStart)
        #expect(try DropboxContentHash.hash(single) == DropboxContentHash.hash(parallel))
        #expect(parallelTime < singleTime * 0.85)
        print("Dropbox 32MiB connection128/aggregate512 Mbps: single=\(singleTime)s parallel=\(parallelTime)s")
        let empty = try await client.metadata("id:empty"); let emptyID = UUID()
        let emptyURL = try await client.download(empty, operationID: emptyID)
        #expect(try Data(contentsOf: emptyURL).isEmpty)
        #expect(try await client.download(empty, operationID: emptyID) == emptyURL)
        try await server.configure(["files": [["id": empty.id, "path": "/empty", "size": 0]]])
        await #expect(throws: DropboxError.sourceChanged) { try await client.download(empty, operationID: emptyID) }
        let operation = UUID(); let control = ProgressStop()
        await #expect(throws: FileOperationError.self) {
            try await client.download(
                file, operationID: operation, maximumConnections: 1,
                context: .init(checkpoint: { try control.check() }, progress: { n, _ in control.progress(n) }))
        }
        let interrupted = try #require(try client.journal.load(operation)); #expect(interrupted.offset > 0 && interrupted.offset < 32 << 20)
        let resumed = try await client.download(file, operationID: operation)
        #expect(try DropboxContentHash.hash(resumed) == file.contentHash)
        #expect(try await client.download(file, operationID: operation) == resumed)
        try Data("tampered".utf8).write(to: resumed)
        await #expect(throws: DropboxError.sourceChanged) { try await client.download(file, operationID: operation) }
        for flag in ["wrongRevision", "wrongRange", "corruptDownload"] {
            try await server.configure([flag: true])
            await #expect(throws: (any Error).self, Comment(rawValue: flag)) { try await client.download(file, maximumConnections: 1) }
        }
        var stale = file; stale.rev = "wrong"
        await #expect(throws: (any Error).self) { try await client.download(stale) }
    }

    @Test func instantStreamingThumbnailAndOfflinePreviewTiming() async throws {
        let server = try FakeDropboxServer(latencyMS: 40); let client = try server.client()
        let item = try await client.metadata("id:hello")
        let start = Date(); let preview = try client.streamingPreview(item, contentType: "text/plain")
        defer { preview.stop() }
        let instant = Date().timeIntervalSince(start)
        #expect(try await server.requests().allSatisfy { $0["route"] as? String != "files/download" })
        var request = URLRequest(url: preview.url); request.setValue("bytes=0-4", forHTTPHeaderField: "Range")
        let readStart = Date(); let (bytes, response) = try await URLSession.shared.data(for: request)
        let first = Date().timeIntervalSince(readStart)
        #expect(bytes == Data("Hello".utf8) && (response as? HTTPURLResponse)?.statusCode == 206)
        #expect(instant < 0.25)
        let thumbnail = try await client.thumbnail(item)
        #expect(try Data(contentsOf: thumbnail) == Data("fixture-thumbnail".utf8))
        #expect(try await client.thumbnail(item) == thumbnail)
        let source = client.contentSource
        #expect(source.ref(for: source.url(for: source.remoteItem(item)))?.item == item.id)
        #expect(source.ref(for: DropboxLocation(accountID: UUID(), itemID: item.id).url) == nil)
        let store = try await client.offlineCopies()
        let remote = source.remoteItem(item)
        _ = try await store.fetch(remote, keep: true)
        let count = try await server.requests().count
        let cacheStart = Date(); let cached = try await client.preview(item, store: store); let cacheTime = Date().timeIntervalSince(cacheStart)
        #expect(await client.cachedPreview(item, store: store) == cached)
        #expect(try await server.requests().count == count)
        #expect(try String(contentsOf: cached, encoding: .utf8).hasPrefix("Hello"))
        #expect(await store.snapshot().isKept(item.id))
        try await store.remove([remote.ref]); #expect(try await store.localCopy(remote.ref, revision: remote.revision) == nil)
        print("Dropbox preview timing: stream-created=\(instant)s first5bytes=\(first)s cached-open=\(cacheTime)s")
        await #expect(throws: DropboxError.invalidResponse) { try await client.readRange(item, range: 0..<(2 << 20)) }
    }

    @Test func durableEditConflictKeepsLocalBytesAndRecovery() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let item = try await client.metadata("id:hello")
        let session = try await client.edits.begin(item)
        #expect(await client.edits.holdsCopy(item.id))
        #expect(try await client.edits.begin(item).id == session.id)
        try Data("local changes".utf8).write(to: session.localURL)
        #expect(await client.contentSource.holdsCopy(.init(account: client.contentSource.accountID, item: item.id)))
        let saved = try await client.edits.save(session.id); #expect(saved.state == .saved && saved.file.rev != item.rev)
        #expect(try await client.edits.save(session.id).state == .saved)
        await client.edits.release(session.id); #expect(await !client.edits.holdsCopy(item.id))
        try Data("unsent changes".utf8).write(to: session.localURL)
        try await server.configure(["files": [["id": item.id, "path": "/hello.txt", "text": "other device"]]])
        await #expect(throws: DropboxError.conflict) { try await client.edits.save(session.id) }
        #expect(await client.edits.session(session.id)?.state == .conflict)
        await #expect(throws: DropboxError.conflict) { try await client.edits.save(session.id) }
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "unsent changes")
        let recovered = DropboxEditStore(client: client)
        #expect(await recovered.pending().count == 1)
        #expect(await recovered.holdsCopy(item.id))
        let copy = try await recovered.saveAsCopy(session.id, to: "/preserved-copy.txt")
        #expect(copy.state == .saved && copy.file.id != item.id)
        #expect(try await client.metadata(item.id).contentHash != copy.sentHash)
    }

    @Test func interruptedEditUploadRetainsItsSnapshotAndThenSendsLaterChanges() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let session = try await client.edits.begin(client.metadata("id:hello"))
        try Data("first save".utf8).write(to: session.localURL)
        await #expect(throws: CancellationError.self) {
            try await client.edits.save(session.id, context: .init(checkpoint: { throw CancellationError() }))
        }
        let interrupted = try #require(await client.edits.session(session.id))
        #expect(interrupted.uploadOperation != nil)
        try Data("second save".utf8).write(to: session.localURL, options: .atomic)
        // Simulate relaunch: the durable operation and its upload inode must both survive.
        let recovered = DropboxEditStore(client: client)
        let first = try await recovered.save(session.id)
        if case .unsent = first.state {} else { Issue.record("later edits must remain pending") }
        #expect(first.sentHash == DropboxContentHash.hash(Data("first save".utf8)))
        #expect(try await client.metadata(session.file.id).contentHash == first.sentHash)
        let second = try await recovered.save(session.id)
        #expect(second.state == .saved && second.sentHash == DropboxContentHash.hash(Data("second save".utf8)))
        #expect(try await client.metadata(session.file.id).contentHash == second.sentHash)
    }

    @Test func cacheFallbackPaginationLoopsBackoffAndProviderErrors() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let files = try await client.list()
        let down = CloudHTTPTransport(send: { _ in throw URLError(.notConnectedToInternet) })
        let offline = DropboxClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens,
            directory: server.directory, http: down)
        #expect(try await offline.list() == files && offline.isOffline)
        let source = client.contentSource
        let wrong = CloudItemRef(account: "other", item: "id:hello")
        #expect(source.cachedItem(wrong) == nil)
        await #expect(throws: CloudContentError.unsupported) { try await source.item(wrong) }
        await #expect(throws: CloudContentError.notFound) { try await source.item(.init(account: source.accountID, item: "id:missing")) }
        #expect(try await source.children(.init(account: source.accountID, item: "")).count == 3)
        #expect(try await source.item(.init(account: source.accountID, item: "")).isFolder)
        try await server.configure(["pageSize": 1, "repeatCursor": true])
        await #expect(throws: DropboxError.invalidResponse) { try await client.list() }
        try await server.configure(["repeatCursor": false, "backoff": 1])
        try await client.changes.check(); _ = try await client.changes.pollOnce()
        let start = Date(); _ = try await client.changes.pollOnce()
        #expect(Date().timeIntervalSince(start) >= 0.9)
        try await server.configure(["denyToken": true])
        let fresh = try server.client()
        await #expect(throws: DropboxError.reconnect) { try await fresh.metadata("id:hello") }
    }

    @Test func zeroByteUploadLocalChangesAndSourceDiscardRecovery() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let local = server.fixture.scratch.url.appendingPathComponent("empty"); try Data().write(to: local)
        let empty = try await client.upload(local, to: "/empty")
        #expect(empty.size == 0 && empty.contentHash == DropboxContentHash.hash(Data()))
        try Data(repeating: 3, count: (8 << 20) + 10).write(to: local)
        let changed = UUID()
        await #expect(throws: DropboxError.sourceChanged) {
            try await client.upload(
                local, to: "/changed", operationID: changed,
                context: .init(progress: { done, _ in
                    if done >= 8 << 20 { try? Data("edited".utf8).write(to: local) }
                }))
        }
        await #expect(throws: DropboxError.sourceChanged) { try await client.upload(local, to: "/changed", operationID: changed) }
        try await server.configure(["files": [["id": "id:recover", "path": "/recover", "size": 1 << 20]]])
        let file = try await client.metadata("id:recover"); let source = client.contentSource
        let partial = server.fixture.scratch.url.appendingPathComponent("partial")
        let gate = CountStop(limit: 3)
        await #expect(throws: FileOperationError.self) {
            try await source.download(source.remoteItem(file), to: partial, checkpoint: { try gate.check() }, progress: { _, _ in })
        }
        let sidecar = partial.appendingPathExtension("dropbox-operation"); #expect(FileManager.default.fileExists(atPath: sidecar.path))
        try await source.discardPartial(at: partial)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        try await source.discardPartial(at: partial)
    }

    @Test @MainActor func oauthAccountLifecycleConfigurationAndNoSecret() async throws {
        let server = try FakeDropboxServer(); let scratch = try Scratch(); let credentials = MemoryCredentials()
        let suite = "porpoise-dropbox-test-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(" settings-key ", forKey: "dropboxAppKey")
        #expect(DropboxConfiguration.selected(defaults: defaults, environment: [:]).appKey == "settings-key")
        #expect(
            DropboxConfiguration.selected(defaults: defaults, environment: ["PORPOISE_DROPBOX_APP_KEY": "env-key"], testing: true).appKey == "env-key"
        )
        let store = DropboxAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        let browser: @MainActor (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let account = try await store.connect(openBrowser: browser)
        #expect(account.hasTeamSpace && account.email == "fixture@example.invalid")
        #expect(try credentials.read(clientID: server.config.appKey, accountID: account.id) == "fixture-refresh")
        let persisted = try #require(defaults.data(forKey: "dropboxAccounts"));
        #expect(!String(decoding: persisted, as: UTF8.self).contains("fixture-refresh"))
        await #expect(throws: CloudConnectionError.alreadyConnected(account.id)) { try await store.connect(openBrowser: browser) }
        #expect(try await store.connect(expected: account, openBrowser: browser).id == account.id)
        try await server.configure(["account": "dbid:wrong"])
        await #expect(throws: CloudConnectionError.wrongAccount) { try await store.connect(expected: account, openBrowser: browser) }
        let restored = DropboxAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        #expect(restored.accounts == [account] && restored.client(for: account.id) != nil)
        try await store.checkForChanges(account.id)
        await store.setActive(true); await store.setActive(false)
        let client = try #require(store.client(for: account.id))
        let edit = try await client.edits.begin(client.metadata("id:hello"))
        try Data("pending".utf8).write(to: edit.localURL)
        await #expect(throws: CloudConnectionError.unsentEdits) { try await store.disconnect(account.id) }
        _ = try await client.edits.save(edit.id)
        try await store.disconnect(account.id); #expect(store.accounts.isEmpty)
        #expect(try credentials.read(clientID: server.config.appKey, accountID: account.id) == nil)
        // Nothing of the account stays: its folder (edits, journal, partials) and its offline copies.
        let needle = account.id.uuidString.lowercased()
        for root in [scratch.url, CloudOffline.shared.root] {
            let left = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.lowercased().contains(needle) }
            #expect(left.isEmpty, "\(left)")
        }
        #expect((try await server.stats())["secretSent"] as? Bool == false)
        #expect(CloudProviderDescriptor.catalog(dropbox: .init(appKey: "fixture-app")).first { $0.provider == .dropbox }?.available == true)
    }
}

private final class BatchBox: @unchecked Sendable {
    private let lock = NSLock(); private var batches: [CloudChangeBatch] = []
    func add(_ batch: CloudChangeBatch) { lock.withLock { batches.append(batch) } }
    var values: [CloudChangeBatch] { lock.withLock { batches } }
}
private final class ProgressStop: @unchecked Sendable {
    private let lock = NSLock(); private var stop = false
    func progress(_ bytes: Int64) { lock.withLock { if bytes >= 20 << 20 { stop = true } } }
    func check() throws { try lock.withLock { if stop { throw FileOperationError.interrupted } } }
}

private final class CountStop: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0; let limit: Int
    init(limit: Int) { self.limit = limit }
    func check() throws {
        try lock.withLock {
            count += 1; if count >= limit { throw FileOperationError.interrupted }
        }
    }
}
