import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

extension DriveMutationTests {
    @Test func directoryRoundTripAndMergeSettleTheirJournals() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let source = try scratch.folder("Tree")
        try scratch.file("Tree/nested/a.txt", "alpha")
        try scratch.file("Tree/b.txt", "beta")
        let root = DriveLocation(accountID: client.accountID).url
        func job(_ sources: [URL], _ destination: URL, rule: TransferConflictRule = .ask) -> RemoteTransferJob {
            RemoteTransferJob(
                kind: .copy, sources: sources, destination: destination,
                control: FileJob(kind: .copy, sources: sources, destinationFolder: destination), rule: rule, options: .init(method: .content))
        }
        let upload = job([source], root); upload.run()
        #expect(upload.errors.isEmpty && upload.results.count == 1)
        let cloud = try #require(upload.results.first)
        let output = try scratch.folder("output")
        let download = job([cloud], output); download.run()
        #expect(download.errors.isEmpty)
        #expect(scratch.read("output/Tree/nested/a.txt") == "alpha" && scratch.read("output/Tree/b.txt") == "beta")
        try scratch.file("Tree/new.txt", "new child")
        let merge = job([source], root, rule: .different); merge.run()
        #expect(merge.errors.isEmpty)
        let records = try client.mutationJournal.all(accountID: client.accountID)
        #expect(records.filter { $0.batchID == merge.cloudBatchID && $0.topLevel == true }.allSatisfy { $0.phase == .done })
        #expect(try provider.list(cloud).contains { $0.name == "new.txt" })
        let resumed = job([source], root)
        resumed.cloudOperations = upload.cloudOperations; resumed.cloudBatchID = upload.cloudBatchID
        resumed.run()
        #expect(resumed.errors.isEmpty && resumed.results == [cloud])
    }

    @Test func activityServerCopyAndBothMoveKindsPreserveExpectedIdentity() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let folder = try await client.createFolder(name: "destination", parentID: "root").location(accountID: client.accountID).url
        let binary = try await client.file("binary-a").location(accountID: client.accountID).url
        func run(_ kind: FileOperationKind, _ source: URL, _ target: URL) -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: kind, sources: [source], destination: target,
                control: FileJob(kind: kind, sources: [source], destinationFolder: target), rule: .keepBoth, options: .init())
            job.run(); return job
        }
        let copied = run(.copy, binary, folder)
        #expect(copied.errors.isEmpty && copied.results.first != binary)
        let moved = run(.move, binary, folder)
        #expect(moved.errors.isEmpty)
        let copiedURL = try #require(copied.results.first), movedURL = try #require(moved.results.first)
        #expect(provider.metadata(for: copiedURL)?.name != provider.metadata(for: movedURL)?.name)
        #expect(moved.results.first.flatMap { DriveLocation(url: $0) }?.collection == DriveLocation(url: binary)?.collection)
        let local = try scratch.file("cross.txt", "cross drive bytes")
        let uploaded = try await client.upload(local, parentID: "root").location(accountID: client.accountID).url
        let shared = DriveLocation(accountID: client.accountID, collection: .folder("shared-drive-a", driveID: "shared-drive-a")).url
        let cross = run(.move, uploaded, shared)
        #expect(cross.errors.isEmpty && cross.results.count == 1)
        #expect(try await client.file(DriveLocation(url: uploaded)!.itemIDForTest, includeTrashed: true).trashed == true)
    }

    @Test @MainActor func recoveryPlanOffersResumptionAndDiscardWithoutSourceLoss() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let source = try scratch.file("recover.txt", "recover me")
        var record = DriveMutationRecord(operationID: UUID(), accountID: client.accountID, kind: "transferCopy")
        record.batchID = UUID(); record.topLevel = true; record.localSource = source; record.destinationFolder = root
        record.fingerprint = JobJournal.Fingerprint(source)
        try client.mutationJournal.save(record)
        let controller = makeController(ScriptedUI())
        controller.driveJournals = client.mutationJournal
        controller.journals = JournalStore(folder: try scratch.folder("local-journals"))
        let plans = controller.recoveryPlans()
        let plan = try #require(plans.first { $0.id == record.operationID })
        #expect(plan.sources == [source] && plan.destination == root)
        let results: [URL] = await withCheckedContinuation { continuation in
            controller.recover(plan, window: nil) { continuation.resume(returning: $0) }
        }
        #expect(results.count == 1 && controller.recoveryPlans().isEmpty)
        record = DriveMutationRecord(operationID: UUID(), accountID: client.accountID, kind: "transferMove")
        record.topLevel = true; record.localSource = source; record.destinationFolder = root; record.phase = .sourceRemovalPending
        try client.mutationJournal.save(record)
        let uncertain = try #require(controller.recoveryPlans().first)
        #expect(!uncertain.notes.isEmpty)
        controller.discard(uncertain)
        #expect(controller.recoveryPlans().isEmpty && FileManager.default.fileExists(atPath: source.path))
    }
}

private extension DriveLocation {
    var itemIDForTest: String { if case .folder(let id, _) = collection { return id }; return "root" }
}
