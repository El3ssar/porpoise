import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudTransferJournalTests {
    @Test func legacyDriveImportKeepsOperationIdentityReceiptsAndCanonicalProgress() throws {
        let scratch = try Scratch(), account = UUID(), operation = UUID()
        let legacy = DriveMutationJournal(folder: scratch.url.appendingPathComponent("Legacy"))
        let source = DriveLocation(accountID: account, collection: .folder("source-id")).url
        let target = try scratch.file("published", "bytes")
        var old = DriveMutationRecord(operationID: operation, accountID: account, kind: "transferMove", sourceID: "source-id")
        old.localSource = source; old.destinationFolder = scratch.url; old.destinationURL = target; old.revision = "old-version"
        old.destinationFingerprint = JobJournal.Fingerprint(target); old.phase = .committed; old.topLevel = true
        old.batchID = UUID(); old.childOperationID = UUID(); old.downloadOperationID = UUID()
        try legacy.save(old)
        let journal = DriveProvider.transferJournal(legacy)
        var imported = try #require(try journal.load(operation))
        #expect(imported.operationID == operation && imported.batchID == old.batchID && imported.topLevel)
        #expect(imported.childOperationID == old.childOperationID && imported.downloadOperationID == old.downloadOperationID)
        #expect(imported.source == source && imported.sourceRevision == "old-version" && imported.phase == .committed)
        #expect(imported.receipt?.fingerprint == old.destinationFingerprint && imported.receipt?.url == target)
        imported.phase = .done; try journal.save(imported)
        #expect(try journal.all().count == 1 && journal.load(operation)?.phase == .done)
        #expect(try legacy.load(operation)?.phase == .committed)  // An old record cannot roll canonical progress back.
        #expect(DriveProvider.transferJournal(legacy) === journal)
    }

    @Test func accountStopCancelsAndDrainsOwnersThenFencesLateWritesAndWipesOnlyPrivateData() async throws {
        let scratch = try Scratch(), account = "fixture:" + UUID().uuidString, control = JobControl(), stopped = Flag()
        let journal = CloudTransferJournal.at(scratch.url.appendingPathComponent("Transfers")), id = UUID()
        let source = try scratch.file("original", "original"), target = try scratch.file("published", "published")
        var record = CloudTransferRecord(operationID: id, kind: "move", source: source, destinationFolder: scratch.url)
        record.sourceAccount = account; record.receipt = .init(url: target, fingerprint: JobJournal.Fingerprint(target))
        let privateCopy = journal.folder.appendingPathComponent("Sources").appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: privateCopy, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: privateCopy.appendingPathComponent("bytes"))
        try journal.claim(id, accounts: [account], control: control)
        let released = Flag()
        defer { if !released.isSet { journal.release(id) }; CloudTransferJournal.allow(account: account) }
        try journal.save(record)
        #expect(CloudTransferJournal.isActive(record))
        #expect(throws: CloudJournalError.self) { try journal.claim(id, accounts: [account], control: JobControl()) }
        let stop = Task {
            await CloudTransferJournal.stop(account: account); stopped.set()
        }
        await expectEventually("account cancellation reached the worker") { control.isCancelled }
        #expect(!stopped.isSet)
        record.phase = .transferring
        #expect(throws: CloudContentError.offline) { try journal.save(record) }
        record.phase = .committed; try journal.save(record)  // An in-flight commit can still record its verified receipt.
        journal.release(id); released.set(); await stop.value
        #expect(stopped.isSet && !CloudTransferJournal.isActive(record))
        record.phase = .done
        #expect(throws: CloudContentError.offline) { try journal.save(record) }
        #expect(throws: CloudContentError.offline) { try journal.claim(UUID(), accounts: [account], control: JobControl()) }
        try journal.forget(account: account)
        #expect(try journal.all().isEmpty && !FileManager.default.fileExists(atPath: privateCopy.path))
        #expect(try Data(contentsOf: source) == Data("original".utf8) && Data(contentsOf: target) == Data("published".utf8))
        CloudTransferJournal.allow(account: account)
        let next = UUID(); try journal.claim(next, accounts: [account], control: JobControl()); journal.release(next)
    }
}
