import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// OneDrive in the shared transfer engine (Activity, journals, conflict rules), as CloudTransferIntegrationTests has
/// Drive and Dropbox: exact bytes before a source goes, distinct leg IDs, identical skips without media requests.
@Suite(.serialized, .isolatedSettings) struct OneDriveTransferIntegrationTests {
    private final class Fixture {
        let scratch: Scratch
        let graph: FakeGraphServer
        let dropboxServer: FakeDropboxServer
        let driveServer: FakeDriveServer
        let onedrive: OneDriveClient
        let dropbox: DropboxClient
        let drive: DriveClient
        let provider: OneDriveProvider
        let dropboxProvider: DropboxProvider
        let driveProvider: DriveProvider
        var root: URL { OneDriveLocation(accountID: onedrive.accountID).url }
        var dropboxRoot: URL { DropboxLocation(accountID: dropbox.accountID).url }
        var driveRoot: URL { DriveLocation(accountID: drive.accountID).url }
        init() throws {
            scratch = try Scratch(); graph = try FakeGraphServer(); dropboxServer = try FakeDropboxServer()
            driveServer = try DriveMutationTests().server()
            onedrive = try graph.client(directory: scratch.url.appendingPathComponent("OneDrive"))
            dropbox = try dropboxServer.client(directory: scratch.url.appendingPathComponent("Dropbox"))
            let credentials = MemoryCredentials(), id = UUID()
            try credentials.save("fixture-refresh", clientID: driveServer.config.clientID, accountID: id)
            drive = DriveClient(
                accountID: id, tokens: DriveTokenManager(configuration: driveServer.config, accountID: id, credentials: credentials),
                baseURL: driveServer.base.appendingPathComponent("drive/v3/"),
                mutationJournal: .init(folder: scratch.url.appendingPathComponent("DriveOperations")),
                metadataDirectory: scratch.url.appendingPathComponent("DriveMetadata"))
            provider = OneDriveProvider(client: onedrive); dropboxProvider = DropboxProvider(client: dropbox)
            driveProvider = DriveProvider(accountID: id, client: drive)
            RemoteFS.registerCloud(provider, for: root); RemoteFS.registerCloud(dropboxProvider, for: dropboxRoot)
            RemoteFS.registerDrive(driveProvider, accountID: id)
        }
        deinit {
            RemoteFS.registerCloud(nil, for: root); RemoteFS.registerCloud(nil, for: dropboxRoot)
            RemoteFS.unregisterDrive(accountID: drive.accountID); driveServer.stop()
        }
        func url(_ item: OneDriveItem) -> URL { OneDriveLocation(accountID: onedrive.accountID, itemID: item.id, driveID: FakeGraphServer.drive).url }
        func run(_ kind: FileOperationKind, _ source: URL, _ target: URL, rule: TransferConflictRule = .keepBoth) async -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: kind, sources: [source], destination: target, control: JobControl(), rule: rule, options: .init(method: .content))
            await offThePool { job.run() }; return job
        }
    }

    @Test func oneDriveAndDropboxCopiesAndMovesPublishExactBytesBeforeRemovingSources() async throws {
        let f = try Fixture()
        _ = try await f.onedrive.list()
        let hello = try await f.onedrive.metadata("FIXTURE!hello"), boxHello = try await f.dropbox.metadata("id:hello")
        let helloBytes = try Data(contentsOf: try await f.onedrive.download(hello))
        let copied = await f.run(.copy, f.url(hello), f.dropboxRoot)
        #expect(copied.errors.isEmpty, "\(copied.errors)")
        let copiedID = try f.dropboxProvider.location(#require(copied.results.first)).itemID
        #expect(try await f.dropbox.metadata(copiedID).contentHash == DropboxContentHash.hash(helloBytes))
        #expect(try await f.onedrive.metadata(hello.id).quickXorHash == hello.quickXorHash)  // a copy keeps the source
        let boxURL = DropboxLocation(accountID: f.dropbox.accountID, itemID: boxHello.id).url
        let moved = await f.run(.move, boxURL, f.root)
        #expect(moved.errors.isEmpty && moved.results.count == 1, "\(moved.errors)")
        await #expect(throws: DropboxError.notFound) { try await f.dropbox.metadata(boxHello.id) }
        let movedID = try f.provider.location(#require(moved.results.first)).itemID
        let arrived = try await f.onedrive.metadata(movedID)
        #expect(arrived.name.hasPrefix("hello") && arrived.parentID == "ROOT!101")  // Keep Both: a second hello.txt
        #expect(try Data(contentsOf: try await f.onedrive.download(arrived)) != helloBytes)
        #expect(try DropboxContentHash.hash(try await f.onedrive.download(arrived)) == boxHello.contentHash)
        let record = try #require(try f.dropboxProvider.transferJournal(boxURL).all().first { $0.batchID == moved.cloudBatchID })
        #expect(record.phase == .done && record.childOperationID != record.downloadOperationID && record.receipt?.snapshot?.item.ref.item == movedID)
        // And out of OneDrive: the source goes only after the copy is verified.
        let out = await f.run(.move, f.url(hello), f.dropboxRoot)
        #expect(out.errors.isEmpty, "\(out.errors)")
        await #expect(throws: OneDriveError.notFound) { try await f.onedrive.metadata(hello.id) }
    }

    @Test func driveDocumentsArriveExportedAndDriveFilesExactly() async throws {
        let f = try Fixture()
        let document = try await f.drive.file("doc-a"), binary = try await f.drive.file("binary-a")
        let exported = await f.run(.copy, document.location(accountID: f.drive.accountID).url, f.root)
        #expect(exported.errors.isEmpty, "\(exported.errors)")
        let id = try f.provider.location(#require(exported.results.first)).itemID
        #expect(try await f.onedrive.metadata(id).name == document.name + ".docx")
        let copied = await f.run(.copy, binary.location(accountID: f.drive.accountID).url, f.root)
        let copiedID = try f.provider.location(#require(copied.results.first)).itemID
        let bytes = try await f.drive.download(binary).data
        #expect(try await f.onedrive.metadata(copiedID).quickXorHash == OneDriveContentHash.hash(bytes))
        let hello = try await f.onedrive.metadata("FIXTURE!hello")
        let back = await f.run(.copy, f.url(hello), f.driveRoot)
        #expect(back.errors.isEmpty, "\(back.errors)")
        let backURL = try #require(back.results.first), backID = try #require(DriveLocation(url: backURL)).folderIDOrRoot
        #expect(try await OneDriveContentHash.hash(f.drive.download(f.drive.file(backID)).data) == hello.quickXorHash)
    }

    @Test func sameOneDriveReplacementUsesDifferentLegIDsAndIdenticalSkipCreatesNoMediaRequest() async throws {
        let f = try Fixture(), hello = try await f.onedrive.metadata("FIXTURE!hello")
        _ = try await f.onedrive.list()
        let folder = try await f.onedrive.createFolder(name: "Target")
        let old = try await f.onedrive.upload(f.scratch.file("old", "old target"), to: folder.id, named: "hello.txt")
        let source = f.url(hello), target = f.url(folder)
        let replaced = await f.run(.copy, source, target, rule: .replace)
        #expect(replaced.errors.isEmpty, "\(replaced.errors)")
        let result = try await f.onedrive.metadata(old.id)
        #expect(result.revision != old.revision && result.quickXorHash == hello.quickXorHash)
        #expect(try await f.graph.requests().contains { $0["method"] as? String == "POST" && $0["ifMatch"] as? String == old.revision })
        let record = try #require(try f.provider.transferJournal(source).all().first { $0.batchID == replaced.cloudBatchID })
        #expect(record.phase == .done && record.childOperationID != record.downloadOperationID && record.receipt?.snapshot?.item.ref.item == old.id)
        let before = try await f.graph.requests().filter { $0["route"] as? String == "/download" }.count
        let skipped = await f.run(.copy, source, target, rule: .different)
        #expect(skipped.errors.isEmpty && skipped.progress.skippedIdenticalItems == 1, "\(skipped.errors) \(skipped.progress)")
        let after = try await f.graph.requests().filter { $0["route"] as? String == "/download" }.count
        #expect(after == before)
        let skippedRecord = try #require(try f.provider.transferJournal(source).all().first { $0.batchID == skipped.cloudBatchID })
        #expect(skippedRecord.phase == .done && skippedRecord.skipped && skippedRecord.skippedIdentical)
    }

    @Test func sameAccountMovesAndCopiesStayInOneDrive() async throws {
        let f = try Fixture()
        _ = try await f.onedrive.list()
        let other = try await f.onedrive.metadata("FIXTURE!other"), folder = try await f.onedrive.metadata("FIXTURE!folder")
        let copied = await f.run(.copy, f.url(other), f.url(folder))
        #expect(copied.errors.isEmpty, "\(copied.errors)")
        let moved = await f.run(.move, f.url(other), f.url(folder), rule: .keepBoth)
        #expect(moved.errors.isEmpty, "\(moved.errors)")
        let requests = try await f.graph.requests()
        #expect(requests.contains { ($0["route"] as? String)?.hasSuffix("/copy") == true })
        #expect(!requests.contains { $0["route"] as? String == "/upload" })  // no bytes went through this Mac
        let inside = try await f.onedrive.list(folder.id).map(\.name)
        #expect(inside.filter { $0.hasPrefix("other") }.count == 2 && inside.contains("nested.txt"))
        // A native move is the same item, in its new folder: nothing was re-created.
        let movedItem = try await f.onedrive.metadata(other.id)
        #expect(movedItem.parentID == folder.id && movedItem.quickXorHash == other.quickXorHash)
        #expect(try await f.onedrive.list().allSatisfy { $0.id != other.id })
    }
}
