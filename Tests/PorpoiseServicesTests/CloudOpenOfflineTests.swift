import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct CloudOpenOfflineTests {
    @Test func openEditSaveReopenDownloadsExactlyOnceAndClones() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("Journal"))
        let file = try await client.file("binary-a")
        let store = try await client.offlineCopies()
        let remote = client.contentSource.remoteItem(file)
        try await store.pin([remote.ref])
        let opened = try await client.preview(file)
        let session = try await client.edits.open(file)
        let fm = FileManager.default
        #expect(
            try fm.attributesOfItem(atPath: opened.path)[.systemFileNumber] as? Int != fm.attributesOfItem(atPath: session.localURL.path)[
                .systemFileNumber] as? Int)
        try Data("saved offline engine".utf8).write(to: session.localURL)
        let saved = try await client.edits.save(session.id)
        let reopened = try await client.preview(saved)
        #expect(try Data(contentsOf: reopened) == Data("saved offline engine".utf8))
        #expect(await store.snapshot().entries[file.id]?.item.revision == saved.headRevisionId)
        #expect(await store.snapshot().entries[file.id]?.item.checksum == saved.md5Checksum.map(CloudChecksum.md5))
        #expect(try await client.cachedPreview(saved) == reopened)
        let stats = try await DriveOfflineTests().stats(server)
        let count = stats.requests.filter { $0.contains("alt=media") }.count
        #expect(count == 1)
        print("CLOUD_OPEN_OFFLINE: open -> edit -> save -> reopen media GETs=\(count), independent clone inode, adopted saved revision+MD5")
        await #expect(throws: CloudContentError.heldForEditing) { try await store.remove([remote.ref]) }
        try await store.wipe()
    }
    @Test func googleDocumentQuickLookUsesOnlyRenditionCache() async throws {
        let server = try FakeDriveServer(), scratch = try Scratch()
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("Journal"))
        let files = try await client.list(DriveLocation(accountID: client.accountID))
        let doc = try #require(files.first { $0.isGoogleDocument })
        let preview = try await client.preview(doc)
        #expect(FileManager.default.fileExists(atPath: preview.path))
        let store = try await client.offlineCopies()
        #expect(await store.snapshot().entries[doc.id] == nil)
        try await store.wipe()
    }
}

extension CloudOpenOfflineTests {
    @Test(arguments: [false, true]) func removingARecoveryPartialAlsoRemovesJournalOwnedStaging(completed: Bool) async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("Journal"))
        let file = try await client.file("binary-a"), source = client.contentSource
        let store = try await client.offlineCopies(), item = source.remoteItem(file)
        try await store.remember([item]); try await store.pin([item.ref])
        let folder = store.directory.appendingPathComponent("objects").appendingPathComponent(cloudObjectKey(item.ref.item))
            .appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let operation = UUID(),
            staging = client.mutationJournal.folder.appendingPathComponent("Downloads").appendingPathComponent(operation.uuidString + ".part")
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial bytes".utf8).write(to: staging)
        var record = DriveMutationRecord(operationID: operation, accountID: client.accountID, kind: "download", sourceID: file.id)
        record.phase = .transferring; record.offset = 13; record.fingerprint = JobJournal.Fingerprint(staging)
        try client.mutationJournal.save(record)
        // A completed journal can still precede the move into the store when the process dies.
        record.phase = completed ? .done : .transferring; record.destinationURL = completed ? staging : nil
        try client.mutationJournal.save(record)
        try JSONEncoder().encode(operation).write(to: folder.appendingPathComponent(".operation"))
        try await store.remove([item.ref])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try await store.wipe()
    }
}
