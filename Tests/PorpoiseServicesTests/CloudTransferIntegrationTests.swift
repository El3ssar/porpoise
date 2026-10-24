import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized, .isolatedSettings) struct CloudTransferIntegrationTests {
    private final class Fixture {
        let scratch: Scratch
        let driveServer: FakeDriveServer
        let dropboxServer: FakeDropboxServer
        let drive: DriveClient
        let dropbox: DropboxClient
        let driveProvider: DriveProvider
        let dropboxProvider: DropboxProvider
        var driveRoot: URL { DriveLocation(accountID: drive.accountID).url }
        var dropboxRoot: URL { DropboxLocation(accountID: dropbox.accountID).url }
        init(http: DriveHTTP = .init()) throws {
            scratch = try Scratch(); driveServer = try DriveMutationTests().server(); dropboxServer = try FakeDropboxServer()
            let credentials = MemoryCredentials(), id = UUID()
            try credentials.save("fixture-refresh", clientID: driveServer.config.clientID, accountID: id)
            let tokens = DriveTokenManager(configuration: driveServer.config, accountID: id, credentials: credentials)
            drive = DriveClient(
                accountID: id, tokens: tokens, http: http, baseURL: driveServer.base.appendingPathComponent("drive/v3/"),
                mutationJournal: .init(folder: scratch.url.appendingPathComponent("DriveOperations")),
                metadataDirectory: scratch.url.appendingPathComponent("DriveMetadata"))
            dropbox = try dropboxServer.client(directory: scratch.url.appendingPathComponent("Dropbox"))
            driveProvider = DriveProvider(accountID: id, client: drive); dropboxProvider = DropboxProvider(client: dropbox)
            RemoteFS.registerDrive(driveProvider, accountID: id); RemoteFS.registerCloud(dropboxProvider, for: dropboxRoot)
        }
        deinit { RemoteFS.unregisterDrive(accountID: drive.accountID); RemoteFS.registerCloud(nil, for: dropboxRoot); driveServer.stop() }
        func run(_ kind: FileOperationKind, _ source: URL, _ target: URL, rule: TransferConflictRule = .keepBoth) async -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: kind, sources: [source], destination: target, control: JobControl(), rule: rule, options: .init(method: .content))
            await offThePool { job.run() }; return job
        }
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func aCloudFolderCannotOverwriteAnOrdinaryDestinationSidecar(_ fileSystem: String) async throws {
        let f = try Fixture(), folder = try await f.dropbox.createFolder(name: "ordinary")
        let disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: f.scratch)
        let sidecar = disk.volume.appendingPathComponent("._ordinary")
        try Data("existing user bytes".utf8).write(to: sidecar)
        let source = DropboxLocation(accountID: f.dropbox.accountID, itemID: folder.id).url
        let job = await f.run(.copy, source, disk.volume)
        #expect(job.results.isEmpty && job.errors.contains { $0.contains("reserved for file metadata") })
        #expect(!FileManager.default.fileExists(atPath: disk.volume.appendingPathComponent("ordinary").path))
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "existing user bytes")
        #expect(try await f.dropbox.metadata(folder.id).name == "ordinary")
    }

    @Test func disconnectDrainsInventoryBeforeCachesCanBeWiped() async throws {
        let held = Locked<Callback<Void>?>(nil), forward = DriveHTTP(), stopped = Flag()
        let http = DriveHTTP { request in
            let reply = try await forward.response(request)
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/files/binary-a") == true {
                try await awaitCallback { callback in held.change { $0 = callback } }
            }
            return reply
        }
        let f = try Fixture(http: http)
        defer { held.value?.resume(); CloudTransferJournal.allow(account: f.drive.accountID.uuidString.lowercased()) }
        let source = DriveLocation(accountID: f.drive.accountID, collection: .folder("binary-a")).url
        let destination = f.scratch.url.appendingPathComponent("Published")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let job = RemoteTransferJob(
            kind: .copy, sources: [source], destination: destination, control: JobControl(), rule: .keepBoth, options: .init())
        let worker = Task { await offThePool { job.run() } }
        await expectEventually("inventory response is held") { held.value != nil }
        let stop = Task {
            await CloudTransferJournal.stop(account: f.drive.accountID.uuidString.lowercased()); stopped.set()
        }
        await expectEventually("disconnect cancels the inventory owner") { job.control.isCancelled }
        #expect(!stopped.isSet)
        held.value?.resume()
        await worker.value; await stop.value
        await f.drive.clearCaches()
        #expect(stopped.isSet && job.results.isEmpty)
        #expect(f.drive.cachedFile(for: source) == nil && f.drive.metadataCache.file("binary-a") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func driveAndDropboxCopiesAndMovesPublishExactBytesBeforeRemovingSources() async throws {
        let f = try Fixture()
        let original = try await f.drive.file("binary-a"), hello = try await f.dropbox.metadata("id:hello")
        let driveURL = original.location(accountID: f.drive.accountID).url
        let helloURL = DropboxLocation(accountID: f.dropbox.accountID, itemID: hello.id).url
        let driveBytes = try await f.drive.download(original).data
        let copied = await f.run(.copy, driveURL, f.dropboxRoot)
        #expect(copied.errors.isEmpty)
        let copiedURL = try #require(copied.results.first), copiedID = try f.dropboxProvider.location(copiedURL).itemID
        #expect(try await f.dropbox.metadata(copiedID).contentHash == DropboxContentHash.hash(driveBytes))
        #expect(try await f.drive.file(original.id).trashed != true)
        let reverse = await f.run(.copy, helloURL, f.driveRoot)
        #expect(reverse.errors.isEmpty)
        let reverseURL = try #require(reverse.results.first), reverseID = try #require(DriveLocation(url: reverseURL)).folderIDOrRoot
        let reverseBytes = try await f.drive.download(f.drive.file(reverseID)).data
        #expect(DropboxContentHash.hash(reverseBytes) == hello.contentHash)
        let moved = await f.run(.move, helloURL, f.driveRoot)
        #expect(moved.errors.isEmpty && moved.results.count == 1)
        await #expect(throws: DropboxError.notFound) { try await f.dropbox.metadata(hello.id) }
        let movedURL = try #require(moved.results.first)
        let movedID = try #require(DriveLocation(url: movedURL)).folderIDOrRoot
        #expect(try await f.drive.download(f.drive.file(movedID)).data == reverseBytes)
        let record = try #require(try f.dropboxProvider.transferJournal(helloURL).all().first { $0.batchID == moved.cloudBatchID })
        #expect(record.phase == .done && record.childOperationID != record.downloadOperationID && record.receipt?.snapshot?.item.ref.item == movedID)
    }

    @Test func sameDropboxReplacementUsesDifferentLegIDsAndIdenticalSkipCreatesNoMediaRequest() async throws {
        let f = try Fixture(), hello = try await f.dropbox.metadata("id:hello")
        let folder = try await f.dropbox.createFolder(name: "Target")
        let old = try await f.dropbox.upload(f.scratch.file("old", "old target"), to: "/Target/hello.txt")
        let source = DropboxLocation(accountID: f.dropbox.accountID, itemID: hello.id).url
        let target = DropboxLocation(accountID: f.dropbox.accountID, itemID: folder.id).url
        let replaced = await f.run(.copy, source, target, rule: .replace)
        #expect(replaced.errors.isEmpty)
        let result = try await f.dropbox.metadata(old.id)
        #expect(result.rev != old.rev && result.contentHash == hello.contentHash)
        let record = try #require(try f.dropboxProvider.transferJournal(source).all().first { $0.batchID == replaced.cloudBatchID })
        #expect(record.phase == .done && record.childOperationID != record.downloadOperationID && record.receipt?.snapshot?.item.ref.item == old.id)
        let before = try await f.dropboxServer.requests().filter { $0["route"] as? String == "files/download" }.count
        let skipped = await f.run(.copy, source, target, rule: .different)
        #expect(skipped.errors.isEmpty && skipped.progress.skippedIdenticalItems == 1)
        let after = try await f.dropboxServer.requests().filter { $0["route"] as? String == "files/download" }.count
        #expect(after == before)
        let skippedRecord = try #require(try f.dropboxProvider.transferJournal(source).all().first { $0.batchID == skipped.cloudBatchID })
        #expect(skippedRecord.phase == .done && skippedRecord.skipped && skippedRecord.skippedIdentical)
    }

    @Test func nativeDocumentExportIsACopyAndCannotAuthorizeMovingTheOriginal() async throws {
        let f = try Fixture(), document = try await f.drive.file("doc-a")
        let source = document.location(accountID: f.drive.accountID).url
        let copy = await f.run(.copy, source, f.dropboxRoot)
        #expect(copy.errors.isEmpty)
        let id = try f.dropboxProvider.location(#require(copy.results.first)).itemID
        #expect(try await f.dropbox.metadata(id).name == document.name + ".docx")
        let before = try await f.dropbox.list().count
        let move = await f.run(.move, source, f.dropboxRoot)
        #expect(move.errors.count == 1 && move.results.isEmpty)
        let after = try await f.dropbox.list().count, preserved = try await f.drive.file(document.id)
        #expect(after == before && preserved.trashed != true)
    }
}
