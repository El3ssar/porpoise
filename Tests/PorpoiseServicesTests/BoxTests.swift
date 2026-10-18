import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The engine checks Drive, Dropbox and OneDrive pass, against the fake Box server (scripts/fake-box-server.py).
@Suite(.serialized) struct BoxTests {
    @Test func opaqueLocationsNamesAndSHA1() throws {
        let id = UUID()
        let location = BoxLocation(accountID: id, itemID: "ID/opaque+%=😀é", kind: .file)
        #expect(BoxLocation(url: location.url) == location)
        #expect(location.url.absoluteString.unicodeScalars.allSatisfy { $0.isASCII })
        let root = BoxLocation(accountID: id)
        #expect(BoxLocation(url: root.url) == root && root.apiID == "0" && root.kind == .folder)
        for raw in [
            "box://invalid/", "box://\(id)/a/b", "box://\(id)/a?bad=x", "box://\(id)/a?type=nope", "box://user@\(id)/", "box://\(id)/a#f",
            "box://\(id)/0",
        ] {
            #expect(BoxLocation(url: URL(string: raw)!) == nil, Comment(rawValue: raw))
        }
        for name in ["..", ".", "a/b", "a\\b", "", "a\u{1}b", " lead", "trail ", String(repeating: "x", count: 256)] {
            #expect(throws: BoxError.invalidLocation) { try BoxClient.validateName(name) }
        }
        try BoxClient.validateName("café: 😀?")
        // FIPS 180 vectors.
        #expect(BoxContentHash.hash(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(BoxContentHash.hash(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(BoxContentHash.digest(hex: "a9993e364706816aba3e25717850c26c9cd0d89d") == BoxContentHash.digest(Data("abc".utf8)))
        #expect(BoxContentHash.digest(hex: "zz") == nil)
        let scratch = try Scratch(); let file = scratch.url.appendingPathComponent("big")
        let big = Data((0..<((3 << 20) + 5)).map { UInt8(truncatingIfNeeded: $0 &* 31) }); try big.write(to: file)
        #expect(try BoxContentHash.hash(file) == BoxContentHash.hash(big))
        #expect(try CloudChecksum.sha1(BoxContentHash.hash(big).uppercased()).verify(file))
        #expect(try !CloudChecksum.sha1("da39a3ee5e6b4b0d3255bfef95601890afd80709").verify(file))
    }

    @Test func boxItemsDecodeAsDocumentedAndRoundTrip() throws {
        // https://developer.box.com/reference/resources/file/ (example values).
        let file = Data(
            #"{"type":"file","id":"12345","etag":"1","sequence_id":"3","name":"Contract.pdf","size":629644,"sha1":"85136c79cbf9fe36bb9d05d0639c70c265c18d37","file_version":{"type":"file_version","id":"12345","sha1":"134b65991ed521fcfe4724b7d814ab8ded5185dc"},"parent":{"type":"folder","id":"12345","etag":"1","name":"Contracts"},"item_status":"active","modified_at":"2012-12-12T10:53:43-08:00","shared_link":null}"#
                .utf8)
        let decoded = try JSONDecoder().decode(BoxItem.self, from: file)
        #expect(decoded.kind == .file && decoded.size == 629644 && decoded.revision == "12345" && decoded.parentID == "12345" && decoded.etag == "1")
        #expect(decoded.canDownload && !decoded.isDeleted)
        let cached = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(BoxItem.self, from: cached) == decoded)
        let root = try JSONDecoder().decode(
            BoxItem.self, from: Data(#"{"type":"folder","id":"0","name":"All Files","etag":null,"parent":null}"#.utf8))
        #expect(root.isRoot && root.isFolder && !root.canDownload && root.location.itemID == "")
        let trashed = try JSONDecoder().decode(BoxItem.self, from: Data(#"{"type":"file","id":"9","name":"x","item_status":"trashed"}"#.utf8))
        #expect(trashed.isDeleted && !trashed.canDownload)
        let link = try JSONDecoder().decode(
            BoxItem.self, from: Data(#"{"type":"web_link","id":"7","name":"Site","url":"https://example.invalid"}"#.utf8))
        #expect(link.kind == .webLink && !link.canDownload && !link.isFolder)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BoxItem.self, from: Data(#"{"type":"comment","id":"1"}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BoxItem.self, from: Data(#"{"type":"file","id":""}"#.utf8)) }
    }

    @Test func pagingSearchRefreshAndSnapshots() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let items = try await client.list(); #expect(items.map(\.name) == ["Bookmark", "Folder", "hello.txt", "other.txt"])
        #expect(client.metadataCache.snapshot("0")?.files.count == 4)
        // Paged by Box's opaque marker (two to a page here).
        #expect(try await server.requests().filter { ($0["query"] as? [String: String])?["marker"] != nil }.count == 1)
        let nested = try await client.list("11"); #expect(nested.map(\.id) == ["22"])
        let a = try await client.search("txt"); #expect(a.items.count == 2 && a.cursor == "2")
        let b = try await client.search("txt", cursor: a.cursor); #expect(b.items.count == 1 && b.cursor == nil)
        #expect(try await client.search("nested", in: "11").items.map(\.id) == ["22"])
        let namesOnly = try #require((try await server.stats())["searchNamesOnly"] as? [Bool])
        #expect(namesOnly.allSatisfy { $0 })
        _ = try await client.search("txt", contents: true)
        #expect(((try await server.stats())["searchNamesOnly"] as? [Bool])?.last == false)
        try await server.configure(["rejectAuthOnce": true]); _ = try await client.metadata("21")
        await #expect(throws: BoxError.notFound) { try await client.metadata("missing", kind: .file) }
        // An unknown type is looked up as a file, then as a folder.
        #expect(try await client.metadata("11").isFolder)
        #expect((try await server.stats())["tokens"] as? Int == 2)
        let restored = BoxClient(accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory)
        #expect(restored.metadataCache.snapshot("0")?.files.count == 4)
        #expect(try await client.quota() == BoxClient.Quota(used: 4_000_000_000, total: 10_737_418_240))
        try await server.configure(["quota": ["space_amount": 999_999_999_999_999 as Int64, "space_used": 5]])
        #expect(try await client.quota() == BoxClient.Quota(used: 5, total: nil))
        // A marker seen twice would page forever: refused.
        try await server.configure(["pageSize": 1, "repeatMarker": true]); client.metadataCache.clear()
        await #expect(throws: BoxError.invalidResponse) { try await client.list() }
        let requests = try await server.requests()
        #expect(requests.filter { ($0["route"] as? String)?.hasPrefix("/2.0/") == true }.allSatisfy { $0["auth"] as? Bool == true })
        let stats = try await server.stats()
        #expect(stats["wrongSecret"] as? Bool == false && (stats["grants"] as? [String])?.allSatisfy { $0 == "refresh_token" } == true)
    }

    @Test func eventsApplyRepeatsDeletesDescendantsAndResets() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        _ = try await client.list(); _ = try await client.list("11")
        let source = client.contentSource
        let batch = Locked([CloudChangeBatch]()); source.onChanges = { batch.append($0) }
        try await client.changes.check()
        let initial = try #require(client.metadataCache.cursor("changes"))
        // The first check starts from now: it doesn't read the whole account.
        #expect(try await server.requests().contains { ($0["query"] as? [String: String])?["stream_position"] == "now" })
        try await server.configure(["files": [["id": "41", "name": "new.txt", "parent": "11", "text": "new"]], "remove": ["21"]])
        try await client.changes.check()
        #expect(client.metadataCache.file("21") == nil)
        #expect(client.metadataCache.snapshot("11")?.files.contains { $0.id == "41" } == true)
        #expect(batch.value.contains { $0.removed.contains("21") })
        #expect(client.metadataCache.cursor("changes") != initial)
        // Paged and repeated: Box may send fewer than asked and the same event twice; the stream is read to its end.
        try await server.configure([
            "eventPageSize": 2, "repeatEvents": true, "files": (1...5).map { ["id": "5\($0)", "name": "p\($0).txt", "text": "\($0)"] },
        ])
        try await client.changes.check()
        #expect((1...5).allSatisfy { client.metadataCache.file("5\($0)") != nil })
        // Only the folder is reported trashed: what was inside goes with it.
        try await server.configure(["remove": ["11"]])
        try await client.changes.check()
        #expect(client.metadataCache.file("22") == nil && client.metadataCache.file("41") == nil)
        #expect(batch.value.contains { $0.removed.contains("22") })
        // An unknown position resets and starts again from now.
        client.metadataCache.setCursor("expired", scope: "changes")
        try await client.changes.check(); #expect(batch.value.contains { $0.reset })
        #expect(client.metadataCache.cursor("changes") != "expired")
        await client.changes.start(); await client.changes.start(); await client.changes.stop()
    }

    @Test func longPollAsksTheRealtimeServerWithoutTheBearer() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        try await server.configure(["longPollSeconds": 0.2])
        try await client.changes.check()
        #expect(try await !client.changes.pollOnce())
        try await server.configure(["files": [["id": "61", "name": "later.txt", "text": "later"]]])
        #expect(try await client.changes.pollOnce())
        #expect(client.metadataCache.file("61") != nil)
        let requests = try await server.requests()
        let polls = requests.filter { $0["route"] as? String == "/realtime" }
        #expect(polls.count >= 2 && polls.allSatisfy { $0["auth"] as? Bool == false })
        #expect(requests.contains { $0["method"] as? String == "OPTIONS" && $0["auth"] as? Bool == true })
    }

    @Test func journaledMutationsConditionalUncertainAndRestore() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        _ = try await client.list()
        let id = UUID(); let folder = try await client.createFolder(name: "café😀", operationID: id)
        #expect(try await client.createFolder(name: "café😀", operationID: id) == folder)
        await #expect(throws: BoxError.conflict) { try await client.createFolder(name: "CAFÉ😀".lowercased()) }
        let file = try await client.metadata("21")
        let renamed = try await client.rename(file, to: "renamed.txt")
        #expect(renamed.id == file.id && renamed.name == "renamed.txt" && renamed.revision == file.revision && renamed.etag != file.etag)
        await #expect(throws: BoxError.conflict) { try await client.rename(renamed, to: "other.txt") }
        // The etag read before the rename no longer holds: refused, not applied over the change.
        await #expect(throws: BoxError.conflict) { try await client.rename(file, to: "stale.txt") }
        let copyID = UUID()
        let copied = try await client.copy(renamed, to: "11", named: "copy.txt", operationID: copyID)
        #expect(copied.id != file.id && copied.parentID == "11" && copied.sha1 == file.sha1)
        #expect(try await client.copy(renamed, to: "11", named: "copy.txt", operationID: copyID) == copied)
        await #expect(throws: BoxError.conflict) { try await client.copy(renamed, to: "11", named: "copy.txt") }
        let moved = try await client.move(copied, to: "", named: "moved.txt"); #expect(moved.id == copied.id && moved.parentID == "0")
        var stale = moved; stale.etag = "stale"
        await #expect(throws: BoxError.conflict) { try await client.delete(stale) }
        _ = try await client.delete(moved)
        await #expect(throws: BoxError.notFound) { try await client.metadata(moved.id) }
        // Undo: back from the trash where it was, by the type remembered from the delete.
        let back = try await client.restore(moved.id)
        #expect(back.id == moved.id && back.parentID == "0" && back.name == "moved.txt")
        _ = try await client.delete(back)
        _ = try await client.createFolder(name: "moved.txt")
        await #expect(throws: BoxError.conflict) { try await client.restore(moved.id) }  // its name is taken: nothing replaced
        _ = try await client.delete(folder)
        #expect(try await client.restore(folder.id, kind: .folder).isFolder)
        await #expect(throws: BoxError.unsupportedUndo) { try await client.restore("never-seen") }
        try await server.configure(["loseMutation": true])
        let uncertain = UUID()
        await #expect(throws: (any Error).self) { try await client.createFolder(name: "applied", operationID: uncertain) }
        await #expect(throws: BoxError.uncertain) { try await client.createFolder(name: "applied", operationID: uncertain) }
        #expect(try await client.list().contains { $0.name == "applied" && $0.isFolder })
        await #expect(throws: BoxError.sourceChanged) { try await client.createFolder(name: "different", operationID: id) }
        let requests = try await server.requests()
        #expect(requests.filter { $0["method"] as? String == "DELETE" }.allSatisfy { $0["ifMatch"] is String })
        #expect(requests.filter { $0["method"] as? String == "PUT" }.allSatisfy { $0["ifMatch"] is String })
        #expect(
            requests.filter { $0["method"] as? String == "DELETE" && ($0["route"] as? String)?.contains("/folders/") == true }.allSatisfy {
                ($0["query"] as? [String: String])?["recursive"] == "true"
            })
    }

    @Test func simpleUploadConditionalReplaceDigestAndUncertainFinish() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let local = server.fixture.scratch.url.appendingPathComponent("input.bin")
        try Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0) }).write(to: local)
        let hash = try BoxContentHash.hash(local)
        let result = try await client.upload(local, to: "", named: "résumé😀.bin")
        #expect(result.size == 70_001 && result.sha1 == hash && result.parentID == "0")
        let fresh = try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result)
        #expect(fresh.id == result.id && fresh.revision != result.revision)
        await #expect(throws: BoxError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result) }
        await #expect(throws: BoxError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin") }
        let posts = try await server.requests().filter { ($0["route"] as? String)?.hasPrefix("/upload/2.0/files/") == true }
        #expect(posts.allSatisfy { $0["contentMD5"] as? String == hash && $0["auth"] as? Bool == true })
        #expect(posts.filter { ($0["route"] as? String)?.hasSuffix("/\(result.id)/content") == true }.allSatisfy { $0["ifMatch"] is String })
        let empty = server.fixture.scratch.url.appendingPathComponent("empty"); try Data().write(to: empty)
        #expect(try await client.upload(empty, to: "11", named: "empty").size == 0)
        try await server.configure(["loseFinish": true]); let lost = UUID()
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
        await #expect(throws: BoxError.uncertain) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
        await #expect(throws: BoxError.invalidLocation) { try await client.upload(server.fixture.scratch.url, to: "", named: "folder") }
        await #expect(throws: BoxError.invalidLocation) { try await client.upload(local, to: "", named: "a/b") }
    }

    @Test func chunkedSessionLostPartResumeCommitPendingAndSecretRedaction() async throws {
        let server = try FakeBoxServer(); let client = try server.client(chunkedThreshold: 1 << 20)
        try await server.configure(["partSize": 1 << 20])
        let local = server.fixture.scratch.url.appendingPathComponent("input.bin")
        try Data((0..<((5 << 19) + 19)).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: local)
        let operation = UUID(); try await server.configure(["loseAppend": true])
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation) }
        let pending = try #require(try client.journal.load(operation)); #expect(pending.phase == "appending" && pending.hasSession)
        let raw = try String(contentsOf: client.journal.folder.appendingPathComponent(operation.uuidString + ".json"), encoding: .utf8)
        #expect(!raw.contains("fixture-session-") && !raw.contains("fixture-refresh"))
        try await server.configure(["commitPendingOnce": true])
        let result = try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation)
        let localHash = try BoxContentHash.hash(local)
        #expect(result.size == Int64((5 << 19) + 19) && result.sha1 == localHash)
        #expect(try await client.tokens.secret(operation) == nil)
        #expect(try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation) == result)
        let requests = try await server.requests()
        let parts = requests.filter { $0["route"] as? String == "/upload/2.0/files/upload_sessions" && $0["method"] as? String == "PUT" }
        // The lost part was found in the session's list: the first part went once, the others once each.
        #expect(parts.filter { ($0["contentRange"] as? String)?.hasPrefix("bytes 0-") == true }.count == 1)
        #expect(parts.count == 3 && parts.allSatisfy { ($0["digest"] as? String)?.hasPrefix("sha=") == true })
        #expect(requests.contains { $0["route"] as? String == "/upload/2.0/files/upload_sessions/parts" })
        #expect(requests.filter { $0["route"] as? String == "/upload/2.0/files/upload_sessions/commit" }.count == 2)  // 202, then done
        // A new version through a session is conditional on the etag at commit.
        let fresh = try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result)
        #expect(fresh.id == result.id && fresh.revision != result.revision)
        await #expect(throws: BoxError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result) }
        let commits = try await server.requests().filter { $0["route"] as? String == "/upload/2.0/files/upload_sessions/commit" }
        #expect(commits.suffix(2).allSatisfy { $0["ifMatch"] is String })
        await #expect(throws: BoxError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin") }  // refused at the session
        try await server.configure(["loseFinish": true]); let lost = UUID()
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
        await #expect(throws: BoxError.uncertain) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
    }

    @Test func rangedDownloadIntegrityResumeSingleAndParallelNumbers() async throws {
        let server = try FakeBoxServer(connectionMbps: 128, bandwidthMbps: 512)
        let client = try server.client()
        try await server.configure(["files": [["id": "71", "name": "large.bin", "size": 32 << 20], ["id": "72", "name": "empty", "size": 0]]])
        let file = try await client.metadata("71")
        // How many ranges are downloaded at once, not how long they took (W-127).
        let start = Date(); let single = try await client.download(file, maximumConnections: 1); let singleTime = Date().timeIntervalSince(start)
        #expect(try await server.stats()["maxConcurrentDownloads"] as? Int == 1)
        try await server.configure(["resetConcurrency": true, "holdDownloads": 2])
        let parallelStart = Date(); let parallel = try await client.download(file); let parallelTime = Date().timeIntervalSince(parallelStart)
        #expect(try await server.stats()["maxConcurrentDownloads"] as? Int ?? 0 >= 2)
        #expect(try BoxContentHash.hash(single) == BoxContentHash.hash(parallel))
        print("Box 32MiB connection128/aggregate512 Mbps: single=\(singleTime)s parallel=\(parallelTime)s")
        let requests = try await server.requests()
        let downloads = requests.filter { $0["route"] as? String == "/download" }
        #expect(!downloads.isEmpty && downloads.allSatisfy { $0["auth"] as? Bool == false && $0["range"] is String })
        // The API's redirect was read, not followed with the bearer.
        #expect(requests.contains { $0["route"] as? String == "/2.0/files/71/content" && $0["auth"] as? Bool == true })
        let empty = try await client.metadata("72"); let emptyID = UUID()
        let emptyURL = try await client.download(empty, operationID: emptyID)
        #expect(try Data(contentsOf: emptyURL).isEmpty)
        #expect(try await client.download(empty, operationID: emptyID) == emptyURL)
        try await server.configure(["files": [["id": empty.id, "name": "empty", "size": 0]]])
        await #expect(throws: BoxError.sourceChanged) { try await client.download(empty, operationID: emptyID) }
        let operation = UUID(); let control = ProgressStop()
        await #expect(throws: FileOperationError.self) {
            try await client.download(
                file, operationID: operation, maximumConnections: 1,
                context: .init(checkpoint: { try control.check() }, progress: { n, _ in control.progress(n) }))
        }
        let interrupted = try #require(try client.journal.load(operation)); #expect(interrupted.offset > 0 && interrupted.offset < 32 << 20)
        let resumed = try await client.download(file, operationID: operation)
        #expect(try BoxContentHash.hash(resumed) == file.sha1)
        #expect(try await client.download(file, operationID: operation) == resumed)
        try Data("tampered".utf8).write(to: resumed)
        await #expect(throws: BoxError.sourceChanged) { try await client.download(file, operationID: operation) }
        // Not ready yet (202) is asked again; an expired download URL is fetched again once.
        try await server.configure(["pendingDownloadOnce": true, "expireDownloadOnce": true])
        let waits = Locked([TimeInterval]())
        let patient = try server.client(id: client.accountID, retryWait: { waits.append($0) })
        #expect(try await patient.readRange(file, range: 0..<16).count == 16 && waits.value.count == 1)
        for flag in ["wrongRange", "corruptDownload", "changeDuringDownload"] {
            let current = try await client.metadata(file.id)
            try await server.configure([flag: true])
            await #expect(throws: (any Error).self, Comment(rawValue: flag)) { try await client.download(current, maximumConnections: 1) }
        }
        var stale = try await client.metadata(file.id); stale.versionID = "wrong"
        await #expect(throws: (any Error).self) { try await client.download(stale) }
    }

    @Test func instantStreamingThumbnailAndOfflinePreviewTiming() async throws {
        let server = try FakeBoxServer(latencyMS: 40); let client = try server.client()
        let item = try await client.metadata("21")
        let start = Date(); let preview = try client.streamingPreview(item, contentType: "text/plain")
        defer { preview.stop() }
        let instant = Date().timeIntervalSince(start)
        // Created at once: nothing was downloaded to make it.
        #expect(try await server.requests().allSatisfy { $0["route"] as? String != "/download" })
        var request = URLRequest(url: preview.url); request.setValue("bytes=0-4", forHTTPHeaderField: "Range")
        let readStart = Date(); let (bytes, response) = try await URLSession.shared.data(for: request)
        let first = Date().timeIntervalSince(readStart)
        #expect(bytes == Data("Hello".utf8) && (response as? HTTPURLResponse)?.statusCode == 206)
        let thumbnail = try await client.thumbnail(item)
        #expect(try Data(contentsOf: thumbnail) == Data("fixture-thumbnail".utf8))
        #expect(try await client.thumbnail(item) == thumbnail)
        // No rendition yet is a redirect to a generic icon: not a thumbnail, and not followed.
        try await server.configure(["noThumbnail": true])
        let other = try await client.metadata("23")
        await #expect(throws: BoxError.notFound) { try await client.thumbnail(other) }
        #expect(try await server.requests().allSatisfy { $0["route"] as? String != "/placeholder.png" })
        let source = client.contentSource
        #expect(source.ref(for: source.url(for: source.remoteItem(item)))?.item == item.id)
        #expect(source.ref(for: BoxLocation(accountID: UUID(), itemID: item.id, kind: .file).url) == nil)
        let store = try await client.offlineCopies()
        let remote = source.remoteItem(item)
        _ = try await store.fetch(remote, keep: true)
        let count = try await server.requests().count
        let cacheStart = Date(); let cached = try await client.preview(item, store: store); let cacheTime = Date().timeIntervalSince(cacheStart)
        #expect(await client.cachedPreview(item, store: store) == cached)
        #expect(try await server.requests().count == count)  // a warm full copy issues no request
        #expect(try String(contentsOf: cached, encoding: .utf8).hasPrefix("Hello"))
        #expect(await store.snapshot().isKept(item.id))
        try await store.remove([remote.ref]); #expect(try await store.localCopy(remote.ref, revision: remote.revision) == nil)
        print("Box preview timing: stream-created=\(instant)s first5bytes=\(first)s cached-open=\(cacheTime)s")
        await #expect(throws: BoxError.invalidResponse) { try await client.readRange(item, range: 0..<(2 << 20)) }
    }

    @Test func durableEditConflictKeepsLocalBytesAndRecovery() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let item = try await client.metadata("21")
        let session = try await client.edits.begin(item)
        #expect(await client.edits.holdsCopy(item.id))
        #expect(try await client.edits.begin(item).id == session.id)
        try Data("local changes".utf8).write(to: session.localURL)
        #expect(await client.contentSource.holdsCopy(.init(account: client.contentSource.accountID, item: item.id)))
        let saved = try await client.edits.save(session.id); #expect(saved.state == .saved && saved.file.revision != item.revision)
        #expect(try await client.edits.save(session.id).state == .saved)
        await client.edits.release(session.id); #expect(await !client.edits.holdsCopy(item.id))
        try Data("unsent changes".utf8).write(to: session.localURL)
        try await server.configure(["files": [["id": item.id, "name": "hello.txt", "text": "other device"]]])
        await #expect(throws: BoxError.conflict) { try await client.edits.save(session.id) }
        #expect(await client.edits.session(session.id)?.state == .conflict)
        await #expect(throws: BoxError.conflict) { try await client.edits.save(session.id) }
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "unsent changes")
        let recovered = BoxEditStore(client: client)
        #expect(await recovered.pending().count == 1)
        #expect(await recovered.holdsCopy(item.id))
        let copy = try await recovered.saveAsCopy(session.id, named: "preserved-copy.txt")
        #expect(copy.state == .saved && copy.file.id != item.id)
        #expect(try await client.metadata(item.id).sha1 != copy.sentHash)
        #expect(try await server.requests().contains { $0["method"] as? String == "POST" && $0["ifMatch"] as? String == saved.file.etag })
    }

    @Test func interruptedEditUploadRetainsItsSnapshotAndThenSendsLaterChanges() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let session = try await client.edits.begin(client.metadata("21"))
        try Data("first save".utf8).write(to: session.localURL)
        await #expect(throws: CancellationError.self) {
            try await client.edits.save(session.id, context: .init(checkpoint: { throw CancellationError() }))
        }
        let interrupted = try #require(await client.edits.session(session.id))
        #expect(interrupted.uploadOperation != nil)
        try Data("second save".utf8).write(to: session.localURL, options: .atomic)
        let recovered = BoxEditStore(client: client)
        let first = try await recovered.save(session.id)
        if case .unsent = first.state {} else { Issue.record("later edits must remain pending") }
        #expect(first.sentHash == BoxContentHash.hash(Data("first save".utf8)))
        #expect(try await client.metadata(session.file.id).sha1 == first.sentHash)
        let second = try await recovered.save(session.id)
        #expect(second.state == .saved && second.sentHash == BoxContentHash.hash(Data("second save".utf8)))
        #expect(try await client.metadata(session.file.id).sha1 == second.sentHash)
    }

    @Test func verifiedOfflinePartialAfterACrashDoesNotDownloadAgain() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let file = try await client.metadata("21"), source = client.contentSource
        let partial = server.fixture.scratch.url.appendingPathComponent("verified-partial")
        let item = source.remoteItem(file)
        try await source.download(item, to: partial, progress: { _, _ in })
        let before = try await server.requests().filter { $0["route"] as? String == "/download" }.count
        #expect(before > 0)
        let downloads = client.journal.partial(UUID()).deletingLastPathComponent()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).allSatisfy { !$0.hasSuffix(".part") })
        try await source.download(item, to: partial, progress: { _, _ in })
        let after = try await server.requests().filter { $0["route"] as? String == "/download" }.count
        #expect(after == before && (try? BoxContentHash.hash(partial)) == file.sha1)
        try await server.configure(["files": [["id": file.id, "name": "hello.txt", "text": "new revision"]]])
        await #expect(throws: CloudContentError.changed) { try await source.download(item, to: partial, progress: { _, _ in }) }
        #expect(try BoxContentHash.hash(partial) == file.sha1)
    }

    @Test func cacheFallbackThrottlingAndProviderErrors() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let files = try await client.list()
        let down = CloudHTTPTransport(send: { _ in throw URLError(.notConnectedToInternet) })
        let offline = BoxClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory, http: down)
        #expect(try await offline.list() == files && offline.isOffline)
        let source = client.contentSource
        let wrong = CloudItemRef(account: "other", item: "21")
        #expect(source.cachedItem(wrong) == nil)
        await #expect(throws: CloudContentError.unsupported) { try await source.item(wrong) }
        await #expect(throws: CloudContentError.notFound) { try await source.item(.init(account: source.accountID, item: "missing")) }
        #expect(try await source.children(.init(account: source.accountID, item: "")).count == 4)
        #expect(try await source.item(.init(account: source.accountID, item: "")).isFolder)
        #expect(try await source.children(.init(account: source.accountID, item: "")).allSatisfy { $0.parents == [""] })
        #expect(try await source.children(.init(account: source.accountID, item: "")).first { $0.name == "Bookmark" }?.canDownload == false)
        try await server.configure(["failRoute": "files/23"])
        let waits = Locked([TimeInterval]())
        let busy = BoxClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory,
            retryWait: { waits.append($0) })
        await #expect(throws: BoxError.self) { try await busy.metadata("23", kind: .file) }
        #expect(try await server.requests().filter { ($0["route"] as? String)?.hasSuffix("files/23") == true }.count == 5)
        // Retry-After: 0 is honored: each pause is 0 s plus jitter, not the 1, 2, 4, 8 s backoff.
        #expect(waits.value.count == 4 && waits.value.allSatisfy { (0...0.06).contains($0) })
        func status(_ code: Int) -> HTTPURLResponse { HTTPURLResponse(url: server.base, statusCode: code, httpVersion: nil, headerFields: nil)! }
        for code in [429, 503] {
            if case .retry = BoxClient.classify(Data(), status(code), idempotent: false) {} else { Issue.record("\(code)") }
        }
        if case .fail = BoxClient.classify(Data(), status(500), idempotent: false) {} else { Issue.record("500 change") }
        if case .retry = BoxClient.classify(Data(), status(500), idempotent: true) {} else { Issue.record("500 read") }
        #expect(throws: BoxError.conflict) {
            try BoxClient.check(Data(#"{"type":"error","status":409,"code":"item_name_in_use"}"#.utf8), status(409))
        }
        #expect(throws: BoxError.api(403, "access_denied_insufficient_permissions")) {
            try BoxClient.check(Data(#"{"type":"error","code":"access_denied_insufficient_permissions"}"#.utf8), status(403))
        }
        try await server.configure(["failRoute": "", "denyToken": true])
        let fresh = try server.client()
        await #expect(throws: BoxError.reconnect) { try await fresh.metadata("21") }
    }

    @Test func sharedLinksResolveOnlyWhatTheAccountCanOpen() async throws {
        let server = try FakeBoxServer(); let client = try server.client()
        let link = URL(string: "https://app.box.com/s/fixturelink")!
        try await server.configure(["links": [link.absoluteString: "11"], "foreignLinks": ["https://app.box.com/s/foreign"]])
        #expect(try await client.sharedLink(link)?.id == "11")
        #expect(try await client.sharedLink(URL(string: "https://app.box.com/s/foreign")!) == nil)
        #expect(try await client.sharedLink(URL(string: "https://app.box.com/s/gone")!) == nil)
        #expect(try await server.requests().filter { $0["route"] as? String == "/2.0/shared_items" }.allSatisfy { $0["boxApi"] as? Bool == true })
        #expect(CloudProviderDescriptor.linkProvider("https://app.box.com/s/abc")?.provider == .box)
    }

    @Test @MainActor func oauthAccountLifecycleConfigurationRotationAndRevocation() async throws {
        let server = try FakeBoxServer(); let scratch = try Scratch(); let credentials = MemoryCredentials()
        let suite = "porpoise-box-test-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!BoxConfiguration.selected(defaults: defaults, environment: [:], testing: false).isConfigured)
        defaults.set(" settings-id ", forKey: "boxClientID")
        // An ID without its secret is not a configuration, and no other source's secret is paired with it.
        #expect(!BoxConfiguration.selected(defaults: defaults, environment: [:]).isConfigured)
        defaults.set("settings-secret", forKey: "boxClientSecret")
        let settings = BoxConfiguration.selected(defaults: defaults, environment: [:])
        #expect(settings.clientID == "settings-id" && settings.clientSecret == "settings-secret" && settings.isConfigured)
        let env = ["PORPOISE_BOX_CLIENT_ID": "env-id", "PORPOISE_BOX_CLIENT_SECRET": "env-secret"]
        #expect(BoxConfiguration.selected(defaults: defaults, environment: env, testing: true).clientSecret == "env-secret")
        #expect(BoxConfiguration.selected(defaults: defaults, environment: env, testing: false).clientID == "settings-id")
        let store = BoxAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        let account = try await store.connect(openBrowser: openInFakeBrowser)
        #expect(account.email == "fixture@example.invalid" && account.userID == "fixture-user")
        let authorize = try #require((try await server.stats())["authorize"] as? [[String: String]]).first
        #expect(authorize?["code_challenge_method"] == "S256" && authorize?["response_type"] == "code" && authorize?["client_id"] == "fixture-client")
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == "fixture-refresh-1")
        let persisted = try #require(defaults.data(forKey: "boxAccounts"))
        #expect(
            !String(decoding: persisted, as: UTF8.self).contains("fixture-refresh") && !String(decoding: persisted, as: UTF8.self).contains("secret"))
        await #expect(throws: CloudConnectionError.alreadyConnected(account.id)) { try await store.connect(openBrowser: openInFakeBrowser) }
        #expect(try await store.connect(expected: account, openBrowser: openInFakeBrowser).id == account.id)
        try await server.configure(["account": "someone-else"])
        await #expect(throws: CloudConnectionError.wrongAccount) { try await store.connect(expected: account, openBrowser: openInFakeBrowser) }
        try await server.configure(["account": "fixture-user"])
        // Box refresh tokens are single use: a refresh keeps the new one, and a restarted store uses it.
        let restored = BoxAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        #expect(restored.accounts == [account])
        let restoredClient = try #require(restored.client(for: account.id))
        let before = try credentials.read(clientID: server.config.clientID, accountID: account.id)
        _ = try await restoredClient.metadata("21")
        let rotated = try credentials.read(clientID: server.config.clientID, accountID: account.id)
        #expect(rotated?.hasPrefix("fixture-refresh-") == true && rotated != before)
        let edit = try await restoredClient.edits.begin(restoredClient.metadata("21"))
        try Data("pending".utf8).write(to: edit.localURL)
        await #expect(throws: CloudConnectionError.unsentEdits) { try await restored.disconnect(account.id) }
        _ = try await restoredClient.edits.save(edit.id)
        try await restored.disconnect(account.id); #expect(restored.accounts.isEmpty)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == nil)
        #expect((try await server.stats())["revoked"] as? [Bool] == [true])
        let needle = account.id.uuidString.lowercased()
        for root in [scratch.url, CloudOffline.shared.root] {
            let left = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.lowercased().contains(needle) }
            #expect(left.isEmpty, "\(left)")
        }
        #expect((try await server.stats())["wrongSecret"] as? Bool == false)
        let catalog = { (config: BoxConfiguration) in
            CloudProviderDescriptor.catalog(dropbox: .init(appKey: ""), oneDrive: .init(clientID: ""), box: config).first { $0.provider == .box }
        }
        #expect(catalog(.init(clientID: "id", clientSecret: "secret"))?.available == true)
        #expect(catalog(.init(clientID: "id", clientSecret: " "))?.available == false)
        #expect(catalog(.init(clientID: "id", clientSecret: "s"))?.scheme == "box")
        #expect(CloudProvider.box.descriptor.configurations.map(\.key) == ["boxClientID", "boxClientSecret"])
    }
}

private final class ProgressStop: @unchecked Sendable {
    private let lock = NSLock(); private var stop = false
    func progress(_ bytes: Int64) { lock.withLock { if bytes >= 20 << 20 { stop = true } } }
    func check() throws { try lock.withLock { if stop { throw FileOperationError.interrupted } } }
}
