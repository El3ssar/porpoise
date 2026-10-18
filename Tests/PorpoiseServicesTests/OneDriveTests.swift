import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The engine checks Drive and Dropbox pass, against the fake Graph server (scripts/fake-graph-server.py).
@Suite(.serialized) struct OneDriveTests {
    @Test func opaqueLocationsNamesAndQuickXorVectors() throws {
        let id = UUID()
        let location = OneDriveLocation(accountID: id, itemID: "ID!opaque/slash+%=😀é", driveID: "b!drive+opaque/=é")
        #expect(OneDriveLocation(url: location.url) == location)
        #expect(location.url.absoluteString.unicodeScalars.allSatisfy { $0.isASCII })
        for raw in ["onedrive://invalid/", "onedrive://\(id)/a/b", "onedrive://\(id)/a?bad=x", "onedrive://user@\(id)/", "onedrive://\(id)/a#f"] {
            #expect(OneDriveLocation(url: URL(string: raw)!) == nil)
        }
        for name in ["..", ".", "a/b", "a\\b", "", "\0", "a:b", " lead", "trail "] {
            #expect(throws: OneDriveError.invalidLocation) { try OneDriveClient.validateName(name) }
        }
        // Vectors from rclone's independent implementation (backend/onedrive/quickxorhash, MIT).
        let vectors: [(String, String)] = [
            ("", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="), ("Sg==", "SgAAAAAAAAAAAAAAAQAAAAAAAAA="),
            (
                "Mb7EGva2rEE5fENDL85P+BsapHEEjv2/siVhKjvAQe02feExVOQSkfmuYzU/kTF1MaKjPmKF/w+cbvwfdWL8aQ==",
                "n1anP5NfvD4XDYWIeRPW3ZkPv1Y="
            ),
            (
                "jyibxJSzO6ZiZ0O1qe3tG/bvIAYssvukh9suIT5wEy1JBINVgPiqdsTW0cOpP0aUfP7mgqLfADkzI/m/GgCuVhr8oFLrOCoTx1/psBOWwhltCbhUx51Icm9aH8tY4Z3ccU+6BKpYQkLCy0B/A9Zc",
                "hZfLIilSITC6N3e3tQ/iSgEzkto="
            ),
            (
                "w0LGhqU1WXFbdavqDE4kAjEzWLGGzmTNikzqnsiXHx2KRReKVTxkv27u3UcEz9+lbMvYl4xFf2Z4aE1xRBBNd1Ke5C0zToSaYw5o4B/7X99nKK2/XaUX1byLow2aju2XJl2OpKpJg+tSJ2fmjIJTkfuYUz574dFX6/VXxSxwGH/xQEAKS5TCsBK3CwnuG1p5SAsQq3gGVozDWyjEBcWDMdy8/AIFrj/y03Lfc/RNRCQTAfZbnf2QwV7sluw4fH3XJr07UoD0YqN+7XZzidtrwqMY26fpLZnyZjnBEt1FAZWO7RnKG5asg8xRk9YaDdedXdQSJAOy6bWEWlABj+tVAigBxavaluUH8LOj+yfCFldJjNLdi90fVHkUD/m4Mr5OtmupNMXPwuG3EQlqWUVpQoYpUYKLsk7a5Mvg6UFkiH596y5IbJEVCI1Kb3D1",
                "e3+wo77iKcILiZegnzyUNcjCdoQ="
            ),
        ]
        for (input, expected) in vectors {
            let bytes = Data(base64Encoded: input)!
            #expect(OneDriveContentHash.hash(bytes) == expected)
            var pieces = QuickXorHash()  // fed in uneven pieces, as a file is read
            for start in stride(from: 0, to: bytes.count, by: 7) { pieces.update(bytes.subdata(in: start..<min(bytes.count, start + 7))) }
            #expect(pieces.finalize() == expected)
        }
        let scratch = try Scratch(); let file = scratch.url.appendingPathComponent("big")
        let big = Data((0..<((3 << 20) + 5)).map { UInt8(truncatingIfNeeded: $0 &* 31) }); try big.write(to: file)
        #expect(try OneDriveContentHash.hash(file) == OneDriveContentHash.hash(big))
        #expect(try CloudChecksum.quickXor(OneDriveContentHash.hash(big)).verify(file))
        #expect(try !CloudChecksum.quickXor("AAAAAAAAAAAAAAAAAAAAAAAAAAA=").verify(file))
    }

    @Test func graphItemsDecodeAsDocumentedAndRoundTrip() throws {
        // https://learn.microsoft.com/graph/api/resources/driveitem (example values).
        let file = Data(
            #"{"id":"0123456789abc!104","name":"report.docx","eTag":"\"{A},2\"","cTag":"\"c:{A},2\"","size":7212,"parentReference":{"driveId":"0123456789abc","id":"0123456789abc!103"},"file":{"mimeType":"application/vnd.openxmlformats-officedocument.wordprocessingml.document","hashes":{"quickXorHash":"n1anP5NfvD4XDYWIeRPW3ZkPv1Y=","sha1Hash":"X"}},"@microsoft.graph.downloadUrl":"https://secret.example/download?token=x"}"#
                .utf8)
        let decoded = try JSONDecoder().decode(OneDriveItem.self, from: file)
        #expect(!decoded.isFolder && decoded.size == 7212 && decoded.revision == "\"c:{A},2\"" && decoded.parentID == "0123456789abc!103")
        let cached = try JSONEncoder().encode(decoded)
        #expect(!String(decoding: cached, as: UTF8.self).contains("secret.example"))  // a download URL is never kept
        #expect(try JSONDecoder().decode(OneDriveItem.self, from: cached) == decoded)
        let shared = Data(
            #"{"id":"local!1","name":"Plans","remoteItem":{"id":"remote!9","folder":{"childCount":3},"parentReference":{"driveId":"b!other"}}}"#.utf8)
        let target = try JSONDecoder().decode(OneDriveItem.self, from: shared)
        #expect(target.id == "remote!9" && target.driveID == "b!other" && target.isFolder && target.name == "Plans")
        let deleted = try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"x!1","deleted":{"state":"deleted"}}"#.utf8))
        #expect(deleted.isDeleted && !deleted.canDownload)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"x!1","name":"facetless"}"#.utf8)) }
    }

    @Test func pagingSharedSearchDrivesRefreshAndSnapshots() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let items = try await client.list(); #expect(items.map(\.name) == ["Folder", "hello.txt", "other.txt"])
        #expect(client.metadataCache.snapshot("")?.files.count == 3 && client.rootID == "ROOT!101")
        let nested = try await client.list("FIXTURE!folder"); #expect(nested.map(\.id) == ["FIXTURE!nested"])
        let shared = try await client.sharedWithMe()
        #expect(Set(shared.map(\.id)) == ["OTHER!folder", "OTHER!shared.txt"] && shared.allSatisfy { $0.driveID == FakeGraphServer.otherDrive })
        let inside = try await client.driveClient(FakeGraphServer.otherDrive).list("OTHER!folder")
        #expect(inside.map(\.name) == ["inside.txt"])
        let a = try await client.search("txt"); #expect(a.items.count == 2 && a.cursor != nil)
        let b = try await client.search("ignored", cursor: a.cursor); #expect(b.items.count == 1 && b.cursor == nil)
        #expect(try await client.search("nested", in: "FIXTURE!folder").items.map(\.id) == ["FIXTURE!nested"])
        try await server.configure(["rejectAuthOnce": true]); _ = try await client.metadata("FIXTURE!hello")
        await #expect(throws: OneDriveError.notFound) { try await client.metadata("FIXTURE!missing") }
        #expect((try await server.stats())["tokens"] as? Int == 2)
        let restored = OneDriveClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens, driveID: FakeGraphServer.drive,
            directory: server.directory)
        #expect(restored.metadataCache.snapshot("")?.files.count == 3 && restored.rootID == "ROOT!101")
        // A next link on another host would carry the bearer there: refused.
        try await server.configure(["foreignNextLink": true]); client.metadataCache.clear()
        await #expect(throws: OneDriveError.invalidResponse) { try await client.list() }
        let requests = try await server.requests()
        #expect(requests.filter { ($0["route"] as? String)?.hasPrefix("/v1.0/") == true }.allSatisfy { $0["auth"] as? Bool == true })
        let scopes = try #require((try await server.stats())["scopes"] as? [String?])
        #expect(scopes.allSatisfy { $0 == OneDriveConfiguration.scopes })
    }

    @Test func deltaAppliesOpaqueLinksDeletesDescendantsAndResets() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        _ = try await client.list(); _ = try await client.list("FIXTURE!folder")
        let source = client.contentSource
        let batch = Locked([CloudChangeBatch]()); source.onChanges = { batch.append($0) }
        try await client.changes.check()
        let initial = try #require(client.metadataCache.cursor("changes"))
        #expect(initial.contains("delta"))
        // The first check starts from token=latest: it doesn't read the whole drive.
        #expect(try await server.requests().contains { ($0["route"] as? String)?.hasSuffix("/root/delta") == true })
        try await server.configure([
            "files": [["id": "FIXTURE!new", "name": "new.txt", "parent": "FIXTURE!folder", "text": "new"]], "remove": ["FIXTURE!hello"],
        ])
        #expect(try await client.changes.pollOnce())
        #expect(client.metadataCache.file("FIXTURE!hello") == nil)
        #expect(client.metadataCache.snapshot("FIXTURE!folder")?.files.contains { $0.id == "FIXTURE!new" } == true)
        #expect(batch.value.contains { $0.removed.contains("FIXTURE!hello") })
        #expect(client.metadataCache.cursor("changes") != initial)
        #expect(try await !client.changes.pollOnce())
        // Paged: more changes than one page hold arrive in order, the link kept only after each page applies.
        try await server.configure([
            "files": (1...5).map { ["id": "FIXTURE!p\($0)", "name": "p\($0).txt", "text": "\($0)"] }
        ])
        try await client.changes.check()
        #expect((1...5).allSatisfy { client.metadataCache.file("FIXTURE!p\($0)") != nil })
        // Only the folder is reported deleted (as OneDrive for Business may): what was inside goes with it.
        try await server.configure(["remove": ["FIXTURE!folder"]])
        try await client.changes.check()
        #expect(client.metadataCache.file("FIXTURE!nested") == nil && client.metadataCache.file("FIXTURE!new") == nil)
        #expect(batch.value.contains { $0.removed.contains("FIXTURE!nested") })
        // An expired link (410 resyncRequired) resets and starts again from the latest state.
        let link = try #require(client.metadataCache.cursor("changes"))
        client.metadataCache.setCursor(link.replacingOccurrences(of: "token=", with: "token=expired"), scope: "changes")
        try await client.changes.check(); #expect(batch.value.contains { $0.reset })
        #expect(client.metadataCache.cursor("changes")?.contains("expired") == false)
        client.metadataCache.setCursor(link.replacingOccurrences(of: "token=", with: "token=expired"), scope: "changes")
        #expect(try await client.changes.pollOnce())
        await client.changes.start(); await client.changes.start(); await client.changes.stop()
    }

    @Test func journaledMutationsConflictAndUncertainNeverReplay() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        _ = try await client.list()
        let id = UUID(); let folder = try await client.createFolder(name: "café😀", operationID: id)
        #expect(try await client.createFolder(name: "café😀", operationID: id) == folder)
        await #expect(throws: OneDriveError.conflict) { try await client.createFolder(name: "café😀") }
        let file = try await client.metadata("FIXTURE!hello")
        let renamed = try await client.rename(file, to: "renamed.txt")
        #expect(renamed.id == file.id && renamed.name == "renamed.txt" && renamed.revision == file.revision)  // content unchanged
        await #expect(throws: OneDriveError.conflict) { try await client.rename(renamed, to: "other.txt") }
        let copyID = UUID()
        let copied = try await client.copy(renamed, to: "FIXTURE!folder", named: "copy.txt", operationID: copyID)
        #expect(copied.id != file.id && copied.parentID == "FIXTURE!folder" && copied.quickXorHash == file.quickXorHash)
        #expect(try await client.copy(renamed, to: "FIXTURE!folder", named: "copy.txt", operationID: copyID) == copied)
        await #expect(throws: OneDriveError.conflict) { try await client.copy(renamed, to: "FIXTURE!folder", named: "copy.txt") }
        let moved = try await client.move(copied, to: "", named: "moved.txt"); #expect(moved.id == copied.id && moved.parentID == "ROOT!101")
        var stale = moved; stale.eTag = "\"stale\""
        await #expect(throws: OneDriveError.conflict) { try await client.delete(stale) }
        _ = try await client.delete(moved)
        await #expect(throws: OneDriveError.notFound) { try await client.metadata(moved.id) }
        await #expect(throws: OneDriveError.unsupportedUndo) { try await client.delete(folder) }
        _ = try await client.delete(folder, confirmedWithoutUndo: true)
        try await server.configure(["loseMutation": true])
        let uncertain = UUID()
        await #expect(throws: (any Error).self) { try await client.createFolder(name: "applied", operationID: uncertain) }
        await #expect(throws: OneDriveError.uncertain) { try await client.createFolder(name: "applied", operationID: uncertain) }
        #expect(try await client.list().contains { $0.name == "applied" && $0.isFolder })
        await #expect(throws: OneDriveError.sourceChanged) { try await client.createFolder(name: "different", operationID: id) }
        let requests = try await server.requests()
        #expect(requests.filter { $0["route"] as? String == "/monitor" }.allSatisfy { $0["auth"] as? Bool == false })
        #expect(requests.filter { $0["method"] as? String == "DELETE" }.allSatisfy { $0["ifMatch"] is String })
        #expect(requests.filter { ["POST", "PATCH"].contains($0["method"] as? String) }.allSatisfy { $0["conflict"] as? String == "fail" })
    }

    @Test func uploadSessionsLostChunkResumeConditionalSaveAndSecretRedaction() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let local = server.fixture.scratch.url.appendingPathComponent("input.bin")
        try Data((0..<(oneDriveChunk + 19)).map { UInt8(truncatingIfNeeded: $0) }).write(to: local)
        let operation = UUID(); try await server.configure(["loseAppend": true])
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation) }
        let pending = try #require(try client.journal.load(operation)); #expect(pending.phase == "appending" && pending.hasSession)
        let raw = try String(contentsOf: client.journal.folder.appendingPathComponent(operation.uuidString + ".json"), encoding: .utf8)
        #expect(!raw.contains("fixture-session-") && !raw.contains("fixture-refresh"))
        let result = try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation)
        let localHash = try OneDriveContentHash.hash(local)
        #expect(result.size == Int64(oneDriveChunk + 19) && result.quickXorHash == localHash)
        #expect(try await client.tokens.secret(operation) == nil)
        #expect(try await client.upload(local, to: "", named: "résumé😀.bin", operationID: operation) == result)
        let fresh = try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result)
        #expect(fresh.id == result.id && fresh.revision != result.revision)
        await #expect(throws: OneDriveError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin", replacing: result) }
        await #expect(throws: OneDriveError.conflict) { try await client.upload(local, to: "", named: "résumé😀.bin") }
        let requests = try await server.requests()
        // The resumed session continued from what it had: the first chunk went once.
        let chunks = requests.filter { $0["route"] as? String == "/upload" && $0["method"] as? String == "PUT" }
        #expect(chunks.allSatisfy { $0["auth"] as? Bool == false })
        #expect(chunks.filter { ($0["contentRange"] as? String)?.hasPrefix("bytes 0-") == true }.count == 2)  // two files
        #expect(requests.contains { $0["route"] as? String == "/upload" && $0["method"] as? String == "GET" })
        try await server.configure(["loseFinish": true]); let lost = UUID()
        await #expect(throws: (any Error).self) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
        await #expect(throws: OneDriveError.uncertain) { try await client.upload(local, to: "", named: "uncertain.bin", operationID: lost) }
        await #expect(throws: OneDriveError.invalidLocation) { try await client.upload(server.fixture.scratch.url, to: "", named: "folder") }
        await #expect(throws: OneDriveError.invalidLocation) { try await client.upload(local, to: "", named: "a/b") }
    }

    @Test func rangedDownloadIntegrityResumeSingleAndParallelNumbers() async throws {
        let server = try FakeGraphServer(connectionMbps: 128, bandwidthMbps: 512)
        let client = try server.client()
        try await server.configure([
            "files": [["id": "FIXTURE!large", "name": "large.bin", "size": 32 << 20], ["id": "FIXTURE!empty", "name": "empty", "size": 0]]
        ])
        let file = try await client.metadata("FIXTURE!large")
        let start = Date(); let single = try await client.download(file, maximumConnections: 1); let singleTime = Date().timeIntervalSince(start)
        let parallelStart = Date(); let parallel = try await client.download(file); let parallelTime = Date().timeIntervalSince(parallelStart)
        #expect(try OneDriveContentHash.hash(single) == OneDriveContentHash.hash(parallel))
        #expect(parallelTime < singleTime * 0.85)
        print("OneDrive 32MiB connection128/aggregate512 Mbps: single=\(singleTime)s parallel=\(parallelTime)s")
        let downloads = try await server.requests().filter { $0["route"] as? String == "/download" }
        #expect(!downloads.isEmpty && downloads.allSatisfy { $0["auth"] as? Bool == false && $0["range"] is String })
        let empty = try await client.metadata("FIXTURE!empty"); let emptyID = UUID()
        let emptyURL = try await client.download(empty, operationID: emptyID)
        #expect(try Data(contentsOf: emptyURL).isEmpty)
        #expect(try await client.download(empty, operationID: emptyID) == emptyURL)
        try await server.configure(["files": [["id": empty.id, "name": "empty", "size": 0]]])
        await #expect(throws: OneDriveError.sourceChanged) { try await client.download(empty, operationID: emptyID) }
        let operation = UUID(); let control = ProgressStop()
        await #expect(throws: FileOperationError.self) {
            try await client.download(
                file, operationID: operation, maximumConnections: 1,
                context: .init(checkpoint: { try control.check() }, progress: { n, _ in control.progress(n) }))
        }
        let interrupted = try #require(try client.journal.load(operation)); #expect(interrupted.offset > 0 && interrupted.offset < 32 << 20)
        let resumed = try await client.download(file, operationID: operation)
        #expect(try OneDriveContentHash.hash(resumed) == file.quickXorHash)
        #expect(try await client.download(file, operationID: operation) == resumed)
        try Data("tampered".utf8).write(to: resumed)
        await #expect(throws: OneDriveError.sourceChanged) { try await client.download(file, operationID: operation) }
        // An expired download URL is fetched again once.
        try await server.configure(["expireDownloadOnce": true])
        #expect(try await client.readRange(file, range: 0..<16).count == 16)
        for flag in ["wrongRange", "corruptDownload", "changeDuringDownload"] {
            let current = try await client.metadata(file.id)
            try await server.configure([flag: true])
            await #expect(throws: (any Error).self, Comment(rawValue: flag)) { try await client.download(current, maximumConnections: 1) }
        }
        var stale = try await client.metadata(file.id); stale.cTag = "\"wrong\""
        await #expect(throws: (any Error).self) { try await client.download(stale) }
    }

    @Test func instantStreamingThumbnailAndOfflinePreviewTiming() async throws {
        let server = try FakeGraphServer(latencyMS: 40); let client = try server.client()
        let item = try await client.metadata("FIXTURE!hello")
        let start = Date(); let preview = try client.streamingPreview(item, contentType: "text/plain")
        defer { preview.stop() }
        let instant = Date().timeIntervalSince(start)
        #expect(try await server.requests().allSatisfy { $0["route"] as? String != "/download" })
        var request = URLRequest(url: preview.url); request.setValue("bytes=0-4", forHTTPHeaderField: "Range")
        let readStart = Date(); let (bytes, response) = try await URLSession.shared.data(for: request)
        let first = Date().timeIntervalSince(readStart)
        #expect(bytes == Data("Hello".utf8) && (response as? HTTPURLResponse)?.statusCode == 206)
        #expect(instant < 0.25)
        let thumbnail = try await client.thumbnail(item)
        #expect(try Data(contentsOf: thumbnail) == Data("fixture-thumbnail".utf8))
        #expect(try await client.thumbnail(item) == thumbnail)
        #expect(try await server.requests().filter { $0["route"] as? String == "/thumb" }.allSatisfy { $0["auth"] as? Bool == false })
        let source = client.contentSource
        #expect(source.ref(for: source.url(for: source.remoteItem(item)))?.item == item.id)
        #expect(source.ref(for: OneDriveLocation(accountID: UUID(), itemID: item.id, driveID: FakeGraphServer.drive).url) == nil)
        #expect(source.ref(for: OneDriveLocation(accountID: client.accountID, itemID: item.id, driveID: "elsewhere").url) == nil)
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
        print("OneDrive preview timing: stream-created=\(instant)s first5bytes=\(first)s cached-open=\(cacheTime)s")
        await #expect(throws: OneDriveError.invalidResponse) { try await client.readRange(item, range: 0..<(2 << 20)) }
    }

    @Test func durableEditConflictKeepsLocalBytesAndRecovery() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let item = try await client.metadata("FIXTURE!hello")
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
        await #expect(throws: OneDriveError.conflict) { try await client.edits.save(session.id) }
        #expect(await client.edits.session(session.id)?.state == .conflict)
        await #expect(throws: OneDriveError.conflict) { try await client.edits.save(session.id) }
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "unsent changes")
        let recovered = OneDriveEditStore(client: client)
        #expect(await recovered.pending().count == 1)
        #expect(await recovered.holdsCopy(item.id))
        let copy = try await recovered.saveAsCopy(session.id, named: "preserved-copy.txt")
        #expect(copy.state == .saved && copy.file.id != item.id)
        #expect(try await client.metadata(item.id).quickXorHash != copy.sentHash)
        #expect(try await server.requests().contains { $0["method"] as? String == "POST" && $0["ifMatch"] as? String == saved.file.revision })
    }

    @Test func interruptedEditUploadRetainsItsSnapshotAndThenSendsLaterChanges() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let session = try await client.edits.begin(client.metadata("FIXTURE!hello"))
        try Data("first save".utf8).write(to: session.localURL)
        await #expect(throws: CancellationError.self) {
            try await client.edits.save(session.id, context: .init(checkpoint: { throw CancellationError() }))
        }
        let interrupted = try #require(await client.edits.session(session.id))
        #expect(interrupted.uploadOperation != nil)
        try Data("second save".utf8).write(to: session.localURL, options: .atomic)
        let recovered = OneDriveEditStore(client: client)
        let first = try await recovered.save(session.id)
        if case .unsent = first.state {} else { Issue.record("later edits must remain pending") }
        #expect(first.sentHash == OneDriveContentHash.hash(Data("first save".utf8)))
        #expect(try await client.metadata(session.file.id).quickXorHash == first.sentHash)
        let second = try await recovered.save(session.id)
        #expect(second.state == .saved && second.sentHash == OneDriveContentHash.hash(Data("second save".utf8)))
        #expect(try await client.metadata(session.file.id).quickXorHash == second.sentHash)
    }

    @Test func verifiedOfflinePartialAfterACrashDoesNotDownloadAgain() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let file = try await client.metadata("FIXTURE!hello"), source = client.contentSource
        let partial = server.fixture.scratch.url.appendingPathComponent("verified-partial")
        let item = source.remoteItem(file)
        try await source.download(item, to: partial, progress: { _, _ in })
        let before = try await server.requests().filter { $0["route"] as? String == "/download" }.count
        #expect(before > 0)
        try await source.download(item, to: partial, progress: { _, _ in })
        let after = try await server.requests().filter { $0["route"] as? String == "/download" }.count
        #expect(after == before && (try? OneDriveContentHash.hash(partial)) == file.quickXorHash)
        try await server.configure(["files": [["id": file.id, "name": "hello.txt", "text": "new revision"]]])
        await #expect(throws: CloudContentError.changed) { try await source.download(item, to: partial, progress: { _, _ in }) }
        #expect(try OneDriveContentHash.hash(partial) == file.quickXorHash)
    }

    @Test func cacheFallbackPaginationLoopsThrottlingAndProviderErrors() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let files = try await client.list()
        let down = CloudHTTPTransport(send: { _ in throw URLError(.notConnectedToInternet) })
        let offline = OneDriveClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens, driveID: FakeGraphServer.drive,
            directory: server.directory, http: down)
        #expect(try await offline.list() == files && offline.isOffline)
        let source = client.contentSource
        let wrong = CloudItemRef(account: "other", item: "FIXTURE!hello")
        #expect(source.cachedItem(wrong) == nil)
        await #expect(throws: CloudContentError.unsupported) { try await source.item(wrong) }
        await #expect(throws: CloudContentError.notFound) { try await source.item(.init(account: source.accountID, item: "FIXTURE!missing")) }
        #expect(try await source.children(.init(account: source.accountID, item: "")).count == 3)
        #expect(try await source.item(.init(account: source.accountID, item: "")).isFolder)
        #expect(try await source.children(.init(account: source.accountID, item: "")).allSatisfy { $0.parents == [""] })
        try await server.configure(["pageSize": 1, "repeatNextLink": true])
        await #expect(throws: OneDriveError.invalidResponse) { try await client.list() }
        try await server.configure(["repeatNextLink": false, "failRoute": "FIXTURE!other"])
        let busy = Date()
        await #expect(throws: OneDriveError.self) { try await client.metadata("FIXTURE!other") }
        #expect(try await server.requests().filter { ($0["route"] as? String)?.hasSuffix("FIXTURE!other") == true }.count == 5)
        #expect(Date().timeIntervalSince(busy) < 5)  // Retry-After: 0 is honored
        // Classification: throttled and unavailable are retried, a failed change isn't.
        func status(_ code: Int) -> HTTPURLResponse { HTTPURLResponse(url: server.base, statusCode: code, httpVersion: nil, headerFields: nil)! }
        for code in [429, 503] {
            if case .retry = OneDriveClient.classify(Data(), status(code), idempotent: false) {} else { Issue.record("\(code)") }
        }
        if case .fail = OneDriveClient.classify(Data(), status(500), idempotent: false) {} else { Issue.record("500 change") }
        if case .retry = OneDriveClient.classify(Data(), status(500), idempotent: true) {} else { Issue.record("500 read") }
        try await server.configure(["failRoute": "", "denyToken": true])
        let fresh = try server.client()
        await #expect(throws: OneDriveError.reconnect) { try await fresh.metadata("FIXTURE!hello") }
    }

    @Test func zeroByteUploadLocalChangesAndSourceDiscardRecovery() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let local = server.fixture.scratch.url.appendingPathComponent("empty"); try Data().write(to: local)
        let empty = try await client.upload(local, to: "", named: "empty")
        #expect(empty.size == 0 && empty.quickXorHash == OneDriveContentHash.hash(Data()))
        #expect(try await server.requests().contains { $0["method"] as? String == "PUT" && $0["conflict"] as? String == "fail" })
        try Data(repeating: 3, count: oneDriveChunk + 10).write(to: local)
        let changed = UUID()
        await #expect(throws: OneDriveError.sourceChanged) {
            try await client.upload(
                local, to: "", named: "changed", operationID: changed,
                context: .init(progress: { done, _ in
                    if done >= Int64(oneDriveChunk) { try? Data("edited".utf8).write(to: local) }
                }))
        }
        await #expect(throws: OneDriveError.sourceChanged) { try await client.upload(local, to: "", named: "changed", operationID: changed) }
        try await server.configure(["files": [["id": "FIXTURE!recover", "name": "recover", "size": 1 << 20]]])
        let file = try await client.metadata("FIXTURE!recover"); let source = client.contentSource
        let partial = server.fixture.scratch.url.appendingPathComponent("partial")
        let gate = CountStop(limit: 3)
        await #expect(throws: FileOperationError.self) {
            try await source.download(source.remoteItem(file), to: partial, checkpoint: { try gate.check() }, progress: { _, _ in })
        }
        let sidecar = partial.appendingPathExtension("cloud-operation"); #expect(FileManager.default.fileExists(atPath: sidecar.path))
        try await source.discardPartial(at: partial)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        try await source.discardPartial(at: partial)
    }

    @Test @MainActor func oauthAccountLifecycleConfigurationRotationAndNoSecret() async throws {
        let server = try FakeGraphServer(); let scratch = try Scratch(); let credentials = MemoryCredentials()
        let suite = "porpoise-onedrive-test-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(" settings-id ", forKey: "oneDriveClientID")
        #expect(OneDriveConfiguration.selected(defaults: defaults, environment: [:]).clientID == "settings-id")
        #expect(
            OneDriveConfiguration.selected(defaults: defaults, environment: ["PORPOISE_ONEDRIVE_CLIENT_ID": "env-id"], testing: true).clientID
                == "env-id")
        #expect(
            OneDriveConfiguration.selected(defaults: defaults, environment: ["PORPOISE_ONEDRIVE_CLIENT_ID": "env-id"], testing: false).clientID
                == "settings-id")
        let store = OneDriveAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        let account = try await store.connect(openBrowser: openInFakeBrowser)
        #expect(account.email == "fixture@example.invalid" && account.driveID == FakeGraphServer.drive && account.userID == "fixture-user")
        let authorize = try #require((try await server.stats())["authorize"] as? [[String: String]]).first
        #expect(authorize?["code_challenge_method"] == "S256" && authorize?["scope"]?.contains("offline_access") == true)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == "fixture-refresh-1")
        let persisted = try #require(defaults.data(forKey: "oneDriveAccounts"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("fixture-refresh"))
        await #expect(throws: CloudConnectionError.alreadyConnected(account.id)) { try await store.connect(openBrowser: openInFakeBrowser) }
        #expect(try await store.connect(expected: account, openBrowser: openInFakeBrowser).id == account.id)
        try await server.configure(["account": "someone-else"])
        await #expect(throws: CloudConnectionError.wrongAccount) { try await store.connect(expected: account, openBrowser: openInFakeBrowser) }
        try await server.configure(["account": "fixture-user"])
        // Microsoft rotates refresh tokens: a refresh keeps the new one, and a restarted store uses it.
        let restored = OneDriveAccountStore(defaults: defaults, credentials: credentials, configuration: server.config, directory: scratch.url)
        #expect(restored.accounts == [account])
        let restoredClient = try #require(restored.client(for: account.id))
        let before = try credentials.read(clientID: server.config.clientID, accountID: account.id)
        _ = try await restoredClient.metadata("FIXTURE!hello")
        let rotated = try credentials.read(clientID: server.config.clientID, accountID: account.id)
        #expect(rotated?.hasPrefix("fixture-refresh-") == true && rotated != before)
        let edit = try await restoredClient.edits.begin(restoredClient.metadata("FIXTURE!hello"))
        try Data("pending".utf8).write(to: edit.localURL)
        await #expect(throws: CloudConnectionError.unsentEdits) { try await restored.disconnect(account.id) }
        _ = try await restoredClient.edits.save(edit.id)
        try await restored.disconnect(account.id); #expect(restored.accounts.isEmpty)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == nil)
        let needle = account.id.uuidString.lowercased()
        for root in [scratch.url, CloudOffline.shared.root] {
            let left = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.lowercased().contains(needle) }
            #expect(left.isEmpty, "\(left)")
        }
        #expect((try await server.stats())["secretSent"] as? Bool == false)
        #expect(
            CloudProviderDescriptor.catalog(dropbox: .init(appKey: ""), oneDrive: .init(clientID: "id")).first { $0.provider == .oneDrive }?.available
                == true)
        #expect(
            CloudProviderDescriptor.catalog(dropbox: .init(appKey: ""), oneDrive: .init(clientID: " ")).first { $0.provider == .oneDrive }?.available
                == false)
    }
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
