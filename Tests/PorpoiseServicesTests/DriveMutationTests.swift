import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveMutationTests {
    func server() throws -> FakeDriveServer {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/mutations.json")
        return try FakeDriveServer(fixture: fixture)
    }
    func control(_ server: FakeDriveServer, _ values: [String: Any]) async throws {
        var request = URLRequest(url: server.base.appendingPathComponent("__control"))
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: values)
        _ = try await URLSession.shared.data(for: request)
    }
    func client(_ server: FakeDriveServer, folder: URL, id: UUID = UUID(), credentials: MemoryDriveCredentials = .init()) throws
        -> DriveClient
    {
        try credentials.save("fixture-refresh", clientID: server.config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: server.config, accountID: id, credentials: credentials)
        return DriveClient(
            accountID: id, tokens: tokens, baseURL: server.base.appendingPathComponent("drive/v3/"), mutationJournal: .init(folder: folder))
    }

    @Test func createRetryRenameTrashUndoAndMove() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url)
        let op = UUID()
        try await control(server, ["dropCreateResponse": true])
        let folder = try await client.createFolder(name: "Destination", parentID: "root", operationID: op)
        let retried = try await client.createFolder(name: "Destination", parentID: "root", operationID: op)
        #expect(folder.id == retried.id)
        #expect(try await client.list(DriveLocation(accountID: client.accountID)).filter { $0.name == "Destination" }.count == 1)
        let rename = UUID()
        #expect(try await client.rename(folder.id, to: "Renamed", operationID: rename).name == "Renamed")
        #expect(try await client.rename(folder.id, to: "Renamed", operationID: rename).id == folder.id)
        #expect(try await client.move("binary-a", to: folder.id).parents == [folder.id])
        #expect(try await client.setTrashed("binary-a", trashed: true).trashed == true)
        await #expect(throws: DriveError.notFound) { try await client.file("binary-a") }
        #expect(try await client.setTrashed("binary-a", trashed: false).trashed == false)
        #expect(try await client.file("binary-a").id == "binary-a")
        await #expect(throws: DriveError.permissionDenied) { try await client.rename("binary-b", to: "denied") }
        await #expect(throws: DriveError.permissionDenied) { try await client.createFolder(name: "No", parentID: "binary-b") }
        await #expect(throws: DriveMutationError.conflict) { try await client.createFolder(name: "Other", parentID: "root", operationID: op) }
        #expect(try client.mutationJournal.all(accountID: client.accountID).count >= 5)
    }

    @Test func serverCopyLostResponseNeverDuplicatesAndCapabilitiesAreFresh() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url)
        try await control(server, ["dropCreateResponse": true])
        let op = UUID()
        let copy = try await client.copy("binary-a", to: "root", name: "Copy", operationID: op)
        #expect(try await client.copy("binary-a", to: "root", name: "Copy", operationID: op).id == copy.id)
        let list = try await client.list(DriveLocation(accountID: client.accountID))
        #expect(list.filter { $0.name == "Copy" }.count == 1)
        let denied = try await client.file("binary-b")
        #expect(!denied.operations.canWrite && !denied.operations.canRename && denied.operations.canCopy)
        let journal = client.mutationJournal
        var uncertain = DriveMutationRecord(
            operationID: UUID(), accountID: client.accountID, kind: "copy", sourceID: "binary-a", parentID: "root", name: "Lost")
        uncertain.phase = .requesting
        try journal.save(uncertain)
        await #expect(throws: DriveMutationError.uncertain) {
            try await client.copy("binary-a", to: "root", name: "Lost", operationID: uncertain.operationID)
        }
    }

    @Test func quotaBackoffAndScopeUpgrade() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url)
        try await control(server, ["mutationFaults": [429, 429, 0]])
        #expect(try await client.createFolder(name: "After throttle", parentID: "root").isFolder)
        try await control(server, ["mutationFaults": [403]])
        await #expect(throws: DriveError.permissionDenied) { try await client.rename("binary-a", to: "Denied") }
        try await control(server, ["scope": "https://www.googleapis.com/auth/drive.readonly"])
        let readonly = try self.client(server, folder: scratch.url.appendingPathComponent("readonly"))
        await #expect(throws: DriveError.needsWriteAccess) { try await readonly.createFolder(name: "Denied", parentID: "root") }
        // Unknown grants are conservatively treated as old grants too.
        let tx = try DriveOAuthTransaction(configuration: server.config, redirectURL: URL(string: "http://127.0.0.1:12/callback")!)
        #expect(
            URLComponents(url: tx.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value?.contains(
                "auth/drive.readonly") == false)
    }

    @Test func uploadDropAfterChunkRecoversWithNewClientAndIdenticalBytes() async throws {
        let server = try server(), scratch = try Scratch()
        let id = UUID(), credentials = MemoryDriveCredentials()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"), id: id, credentials: credentials)
        let source = scratch.url.appendingPathComponent("large.bin")
        let bytes = Data((0..<800_001).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let op = UUID()
        try await control(server, ["dropUploadResponse": true])
        do { _ = try await client.upload(source, parentID: "root", operationID: op); Issue.record("Expected connection drop") } catch {}
        let before = try #require(try client.mutationJournal.load(op))
        #expect(before.offset == 0 && before.hasSession && before.phase == .transferring)
        let raw = try Data(contentsOf: client.mutationJournal.folder.appendingPathComponent(op.uuidString + ".json"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("/upload/session/"))
        let restarted = try self.client(server, folder: client.mutationJournal.folder, id: id, credentials: credentials)
        let result = try await restarted.upload(source, parentID: "root", operationID: op)
        #expect(result.size == String(bytes.count))
        #expect(try await restarted.download(result).data == bytes)
        #expect(try await restarted.upload(source, parentID: "root", operationID: op).id == result.id)
        #expect(try await restarted.list(DriveLocation(accountID: id)).filter { $0.name == source.lastPathComponent }.count == 1)
        let downloaded = try await restarted.downloadToStaging(result)
        #expect(try Data(contentsOf: downloaded.url) == bytes)
        #expect(try restarted.mutationJournal.load(op)?.phase == .committed)
    }

    @Test func downloadPauseCheckpointRecoveryAndChangedSourceProtection() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let source = scratch.url.appendingPathComponent("large.bin")
        let bytes = Data(repeating: 42, count: 600_000)
        try bytes.write(to: source)
        let uploaded = try await client.upload(source, parentID: "root")
        let op = UUID(), calls = CheckpointCounter()
        let context = DriveTransferContext(checkpoint: { if await calls.next() == 2 { throw FileOperationError.interrupted } })
        await #expect(throws: FileOperationError.self) { try await client.downloadToStaging(uploaded, operationID: op, context: context) }
        #expect(try client.mutationJournal.load(op)?.offset == 0)
        let recovered = try await client.downloadToStaging(uploaded, operationID: op)
        #expect(try Data(contentsOf: recovered.url) == bytes)
        #expect(try await client.downloadToStaging(uploaded, operationID: op).url == recovered.url)
        let changedOp = UUID()
        let stop = DriveTransferContext(checkpoint: { throw FileOperationError.interrupted })
        await #expect(throws: FileOperationError.self) { try await client.upload(source, parentID: "root", operationID: changedOp, context: stop) }
        try Data("changed".utf8).write(to: source)
        await #expect(throws: DriveMutationError.sourceChanged) { try await client.upload(source, parentID: "root", operationID: changedOp) }
        let document = try await client.downloadToStaging(client.file("doc-a"))
        #expect(document.name.hasSuffix(".docx"))
    }

    @Test func providerIdentityTrashPartialSuccessAndInvalidation() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url)
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        _ = try await provider.refresh(root)
        #expect(provider.cachedListing(root) != nil && provider.capabilities(for: root)?.canAddChildren == true)
        let folder = try await provider.createFolder(named: "Duplicate", in: root)
        #expect(provider.cachedListing(root) == nil && folder.name == "Duplicate")
        let second = try await provider.createFolder(named: "Duplicate", in: root)
        #expect(folder.url != second.url)
        let renamed = try await provider.rename(folder.url, to: "Changed")
        #expect(renamed.url == folder.url && renamed.name == "Changed")
        let denied = DriveLocation(accountID: client.accountID, collection: .folder("binary-b")).url
        let result = await provider.trash([folder.url, denied])
        #expect(result.trashed == [folder.url] && result.failures[denied] != nil)
        try await provider.untrash(result.trashed)
        #expect(try await client.file(DriveLocation(url: folder.url)!.collectionID).trashed == false)
    }

    @Test func activityTransfersUseNamesWhileRetainingIDsAndSafeConflictRules() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let local = scratch.url.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: local)
        let root = DriveLocation(accountID: client.accountID).url
        let upload = RemoteTransferJob(
            kind: .copy, sources: [local], destination: root,
            control: FileJob(kind: .copy, sources: [local], destinationFolder: root), rule: .ask, options: .init())
        await offThePool { upload.run() }
        #expect(upload.errors.isEmpty && upload.results.count == 1)
        let remote = try #require(upload.results.first)
        #expect(remote.lastPathComponent != local.lastPathComponent)
        let output = scratch.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let download = RemoteTransferJob(
            kind: .move, sources: [remote], destination: output,
            control: FileJob(kind: .move, sources: [remote], destinationFolder: output), rule: .ask, options: .init())
        await offThePool { download.run() }
        #expect(download.errors.isEmpty)
        #expect(try Data(contentsOf: output.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        #expect(try await client.file(DriveLocation(url: remote)!.collectionID, includeTrashed: true).trashed == true)
        let again = RemoteTransferJob(
            kind: .copy, sources: [local], destination: root,
            control: FileJob(kind: .copy, sources: [local], destinationFolder: root), rule: .ask, options: .init())
        await offThePool { again.run() }
        #expect(again.errors.isEmpty)
        let keepBoth = RemoteTransferJob(
            kind: .copy, sources: [local], destination: root,
            control: FileJob(kind: .copy, sources: [local], destinationFolder: root), rule: .ask, options: .init())
        keepBoth.resolve = { _ in .init(.keepBoth, applyToAll: true) }
        await offThePool { keepBoth.run() }
        #expect(keepBoth.errors.isEmpty)
        let replace = RemoteTransferJob(
            kind: .copy, sources: [local], destination: root,
            control: FileJob(kind: .copy, sources: [local], destinationFolder: root), rule: .ask, options: .init())
        replace.resolve = { _ in .init(.overwrite) }
        await offThePool { replace.run() }
        #expect(replace.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: local.path))
    }
}

private actor CheckpointCounter { var count = 0; func next() -> Int { count += 1; return count } }
private extension DriveLocation {
    var collectionID: String { if case .folder(let id, _) = collection { return id }; return "root" }
}
