import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveM3Tests {
    private func make(_ server: FakeDriveServer, _ folder: URL, id: UUID = UUID(), http: DriveHTTP = .init()) throws -> DriveClient {
        let credentials = MemoryCredentials()
        try credentials.save("fixture-refresh", clientID: server.config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: server.config, accountID: id, credentials: credentials)
        return DriveClient(
            accountID: id, tokens: tokens, http: http, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: folder.appendingPathComponent("Journal")), metadataDirectory: folder)
    }
    @Test func relaunchFirstPaintUsesDiskWithoutRequestAndCorruptionRebuilds() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch(), id = UUID()
        let first = try make(server, scratch.url, id: id)
        let root = DriveLocation(accountID: id).url
        let rows = try await DriveProvider(accountID: id, client: first).refresh(root)
        #expect(!rows.isEmpty)
        let noNetwork = DriveHTTP { _ in
            Issue.record("First paint must not request HTTP"); throw DriveError.offline
        }
        let relaunched = try make(server, scratch.url, id: id, http: noNetwork)
        let provider = DriveProvider(accountID: id, client: relaunched)
        #expect(provider.cachedListing(root)?.map(\.url) == rows.map(\.url))
        #expect(provider.metadata(for: rows[0].url) != nil)
        // A different account has no matching listing, even when the same item IDs exist remotely.
        #expect(DriveProvider(accountID: UUID(), client: nil).cachedListing(root) == nil)
        try Data("broken JSON".utf8).write(to: scratch.url.appendingPathComponent("metadata.json"))
        let rebuilt = try make(server, scratch.url, id: id)
        let recovered = DriveProvider(accountID: id, client: rebuilt)
        #expect(recovered.cachedListing(root) == nil)
        #expect(try await recovered.refresh(root).count == rows.count)
        await rebuilt.clearCaches()
        #expect(rebuilt.metadataCache.snapshot(DriveLocation(accountID: id)) == nil)
    }
    @Test func remoteChangesPatchDiskWithinOnePollAndCursorSurvivesRelaunch() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let root = DriveLocation(accountID: client.accountID)
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        _ = try await provider.refresh(root.url)
        try await client.pollChanges()
        let other = try make(server, scratch.url.appendingPathComponent("Other"))
        try await server.control(["remoteChanges": [["file": ["id": "binary-a", "name": "Changed on phone.txt"]]]])
        try await client.pollChanges()
        #expect(provider.cachedListing(root.url)?.contains { $0.name == "Changed on phone.txt" } == true)
        let relaunched = try make(server, scratch.url, id: client.accountID)
        _ = try await other.createFolder(name: "Browser folder", parentID: "root")
        try await relaunched.pollChanges()
        #expect(relaunched.metadataCache.snapshot(root)?.files.contains { $0.name == "Browser folder" } == true)
        _ = try await other.setTrashed("binary-a", trashed: true)
        try await relaunched.pollChanges()
        #expect(relaunched.metadataCache.snapshot(root)?.files.contains { $0.id == "binary-a" } == false)
    }
    @Test func offlineBrowsingRefusesMutationsThenRefreshReconnects() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let root = DriveLocation(accountID: client.accountID).url
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let rows = try await provider.refresh(root)
        try await server.control(["offline": true])
        #expect(try await provider.refresh(root).count == rows.count)
        #expect(client.isOffline)
        await #expect(throws: DriveError.offline) { try await client.rename("binary-a", to: "Must not send") }
        try await server.control(["offline": false])
        #expect(try await provider.refresh(root).count == rows.count)
        #expect(!client.isOffline)
        #expect(try await client.rename("binary-a", to: "Connected.txt").name == "Connected.txt")
    }
    @Test func editSaveUsesSameIDAndBothKindsOfConflictPreserveBytes() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let file = try await client.file("binary-a")
        let session = try await client.edits.open(file)
        try Data("my first edit".utf8).write(to: session.localURL)
        let result = try await client.edits.save(session.id)
        #expect(result.id == file.id && result.headRevisionId != file.headRevisionId)
        #expect(try await client.download(result).data == Data("my first edit".utf8))
        #expect(await client.edits.pending().isEmpty)
        try Data("my second edit".utf8).write(to: session.localURL)
        let existingDownloads = Set(try client.mutationJournal.all().filter { $0.kind == "download" }.map(\.operationID))
        try await server.control(["conflictOnSave": true])
        await #expect(throws: DriveMutationError.conflict) { try await client.edits.save(session.id) }
        #expect(try await client.download(client.file(file.id)).data == Data("remote edit".utf8))
        #expect(try Data(contentsOf: session.localURL) == Data("my second edit".utf8))
        let conflict = try #require(await client.edits.session(session.id))
        #expect(conflict.state == .conflict)
        #expect(try Data(contentsOf: #require(conflict.conflictURL)) == Data("remote edit".utf8))
        #expect(Set(try client.mutationJournal.all().filter { $0.kind == "download" }.map(\.operationID)) == existingDownloads)
        let reopened = try await client.edits.open(file)
        #expect(reopened.id == session.id)
        let kept = try await client.edits.keepBoth(session.id)
        #expect(kept.id != file.id && kept.name.hasSuffix("(edited on Mac).txt"))
        #expect(try await client.download(kept).data == Data("my second edit".utf8))
        #expect(try await client.download(client.file(file.id)).data == Data("remote edit".utf8))
    }
    @Test func changedBaselineMissingValidatorAndOfflineEditsNeverPublish() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let session = try await client.edits.open(client.file("binary-a"))
        try Data("local unsent".utf8).write(to: session.localURL)
        client.setOffline(true)
        await #expect(throws: DriveError.offline) { try await client.edits.save(session.id) }
        #expect(await client.edits.pending().count == 1)
        #expect(try await client.edits.open(session.file).id == session.id)
        client.setOffline(false)
        try await server.control(["omitETag": true])
        await #expect(throws: DriveMutationError.conflict) { try await client.edits.save(session.id) }
        try await server.control(["omitETag": false])
        _ = try await client.upload(session.localURL, parentID: "root", replacingID: session.file.id)
        await #expect(throws: DriveMutationError.conflict) { try await client.edits.save(session.id) }
        let replaced = try await client.edits.replaceWithMine(session.id)
        #expect(replaced.id == session.file.id)
        let store = DriveEditStore(client: client, directory: scratch.url.appendingPathComponent("Edits"))
        #expect(await store.pending().isEmpty)
        let doc = try await client.file("doc-a")
        await #expect(throws: DriveError.permissionDenied) { try await client.edits.open(doc) }
    }
    @Test func unsentEditsSurviveActualSIGKILL() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch(), id = UUID()
        let repo = TestPaths.repo
        let probe = repo.appendingPathComponent(".build/debug/DriveRecoveryProbe").path
        let status = try await offThePool {
            try runTool(probe, [server.base.absoluteString, scratch.url.path, id.uuidString, UUID().uuidString, "kill", "edit", "binary-a"])
        }.status
        #expect(status == SIGKILL)
        let restored = try make(server, scratch.url.appendingPathComponent("Metadata"), id: id)
        let pending = await restored.edits.pending()
        #expect(pending.count == 1)
        let session = try #require(pending.first)
        #expect(try Data(contentsOf: session.localURL) == Data("durable edit after kill".utf8))
        #expect(try await restored.edits.save(session.id).id == "binary-a")
        #expect(await restored.edits.pending().isEmpty)
    }
    @Test func offlineOpensOnlyPreviouslyCachedPreviewOrEditBytes() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let file = try await client.file("binary-a")
        let preview = try await client.preview(file)
        let session = try await client.edits.open(file)
        client.setOffline(true)
        #expect(try await client.preview(file) == preview)
        #expect(try await client.edits.open(file).id == session.id)
        let unknown = try await client.file("binary-b")
        client.setOffline(true)
        await #expect(throws: DriveError.offline) { try await client.preview(unknown) }
        await client.mediaCache.clear()
        // Full files now have one owner; clearing the legacy OpenFiles seam cannot evict them.
        try await client.offlineCopies().wipe()
        #expect(FileManager.default.fileExists(atPath: session.localURL.path))
        await #expect(throws: DriveError.offline) { try await client.preview(file) }
    }
    @Test func sharedDriveCursorExpiredCursorAndBackoffRecovery() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let shared = DriveLocation(accountID: client.accountID, collection: .sharedDrives)
        _ = try await client.listPage(shared)
        try await client.pollChanges()
        #expect(client.metadataCache.cursor("shared-drive-a") != nil)
        try await server.control(["changeFaults": [503, 0]])
        try await client.pollChanges()
        _ = try await client.file("binary-a")
        let other = try make(server, scratch.url.appendingPathComponent("Other"))
        _ = try await other.setTrashed("binary-a", trashed: true)
        let before = (try await server.stats()["requests"] as? [String])?.count ?? 0
        try await server.control(["changeFaults": [410]])
        try await client.pollChanges()
        #expect(client.metadataCache.cursor("user") != nil && client.metadataCache.cursor("reset:user") == nil)
        #expect(client.metadataCache.file("binary-a") == nil)
        let requests = try #require(try await server.stats()["requests"] as? [String])
        #expect(requests.dropFirst(before).contains { $0.hasPrefix("/drive/v3/changes?") && $0.contains("driveId=shared-drive-a") })
        try await client.pollChanges()
        #expect(client.metadataCache.cursor("user") != nil)
        client.startPolling(interval: 30)
        client.stopPolling()
    }
    @Test func retainedEditStoreFailsCleanlyAfterClientIsReleased() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        var client: DriveClient? = try make(server, scratch.url)
        let file = try await #require(client).file("binary-a")
        let edits = try #require(client).edits
        client = nil
        await #expect(throws: DriveError.reconnect) { try await edits.open(file) }
    }
    @Test func saveBackProbeRoundTripsInItsOwnFolderAndTrashesIt() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let report = await DriveSaveBackProbe(client: client).run()
        #expect(report.passed, "\(report.steps)")
        // As on live Drive: v3 ignores If-Match, which is why saves go through v2's etag.
        #expect(report.steps["staleIfMatch"] == "200" && report.steps["staleBytesKept"] == "overwritten")
        #expect(try await client.list(DriveLocation(accountID: client.accountID)).allSatisfy { $0.name != "Porpoise Probe" })
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("revision-"))
    }
    @Test func saveRefusesAStaleOrMissingEtagWithoutSendingBytes() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let file = try await client.file("binary-a")
        let local = scratch.url.appendingPathComponent("edit.txt")
        try Data("mine".utf8).write(to: local)
        try await server.control(["omitETag": true])
        await #expect(throws: DriveMutationError.conflict) { try await client.saveEdit(local, baseline: file) }
        try await server.control(["omitETag": false, "conflictOnSave": true])
        await #expect(throws: DriveMutationError.conflict) { try await client.saveEdit(local, baseline: file) }
        #expect(try await client.download(client.file("binary-a")).data == Data("remote edit".utf8))
        let current = try await client.file("binary-a")
        #expect(try await client.saveEdit(local, baseline: current).headRevisionId != current.headRevisionId)
        #expect(try await client.download(client.file("binary-a")).data == Data("mine".utf8))
    }
    @Test func fileBackedConditionalSaveAndOpaqueDownloadReleaseStaging() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let file = try await client.file("binary-a")
        let local = scratch.url.appendingPathComponent("large.txt")
        #expect(FileManager.default.createFile(atPath: local.path, contents: nil))
        let output = try FileHandle(forWritingTo: local)
        for _ in 0..<12 { try output.write(contentsOf: Data(repeating: 97, count: 1 << 20)) }
        try output.close()
        let saved = try await client.saveEdit(local, baseline: file)
        #expect(saved.md5Checksum == (try DriveClient.md5(local)))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let remote = DriveLocation(accountID: client.accountID, collection: .folder(saved.id)).url
        let downloaded = try await offThePool { try provider.download(remote, into: scratch.url.appendingPathComponent("Published")) }
        #expect(try DriveClient.md5(downloaded) == saved.md5Checksum)
        #expect(try client.mutationJournal.all().allSatisfy { $0.kind != "download" })
    }
    @Test func searchIsPagedEscapedScopedAndSupportsFullText() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try make(server, scratch.url)
        let root = DriveLocation(accountID: client.accountID)
        try await server.control(["searchPageSize": 1])
        try await server.control(["remoteChanges": [["file": ["id": "binary-a", "description": "a fulltext needle"]]]])
        #expect(try await client.search("fulltext needle", in: root, fullText: true).files.first?.id == "binary-a")
        let page = try await client.search("report", in: root)
        #expect(page.files.count == 1 && page.nextPageToken != nil)
        #expect(try await client.search("report", in: root, pageToken: page.nextPageToken).files.count == 1)
        #expect(try await client.search("missing'\\term", in: root, fullText: true).files.isEmpty)
        let folder = DriveLocation(accountID: client.accountID, collection: .folder("folder-a"))
        #expect(try await client.search("report", in: folder).files.isEmpty)
        await #expect(throws: DriveError.invalidLocation) { try await client.search("a", in: DriveLocation(accountID: UUID())) }
    }
}
