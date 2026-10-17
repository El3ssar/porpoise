import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct TrashServiceTests {
    @Test func allRoutesRecordOriginsAndAFailedBatchRollsBack() throws {
        let scratch = try Scratch()
        let a = try scratch.file("source/a", "a"), b = try scratch.file("source/b", "b")
        let trash = try scratch.folder("trash")
        let service = TrashService { url in
            if url == b { throw CocoaError(.fileWriteNoPermission) }
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        #expect(throws: CocoaError.self) { try service.trash([a, b]) }
        #expect(scratch.read("source/a") == "a" && scratch.read("source/b") == "b")
        #expect(service.originalLocation(of: trash.appendingPathComponent("a")) == nil)
        let result = try service.trash([a])
        #expect(result.count == 1 && service.originalLocation(of: result[0].inTrash) == a)
    }

    @Test func undoAndReplacementUseTheSameOriginLedgerAndRollbackPolicy() throws {
        let scratch = try Scratch(), trash = try scratch.folder("trash")
        let service = TrashService { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        let created = try scratch.file("created", "copy")
        let inverse = try FileActions.undo(.created([created]), trash: service.trash)
        guard case .trashed(let pairs) = inverse else { Issue.record("Expected Trash inverse"); return }
        #expect(service.originalLocation(of: pairs[0].inTrash) == created)
        let staged = try scratch.file(".stage", "previous"), original = scratch.path("report.txt")
        try service.disposeReplacement(staged, original: original)
        let origins = Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:]
        #expect(origins.values.contains(original.path))
        #expect(!FileJob.itemExists(at: staged))
        let failing = TrashService { _ in throw CocoaError(.featureUnsupported) }
        let stage2 = try scratch.file(".stage2", "safe")
        #expect(throws: CocoaError.self) { try failing.disposeReplacement(stage2, original: original) }
        #expect(scratch.read(".stage2") == "safe")
        #expect(scratch.listing().allSatisfy { !$0.hasPrefix(".porpoise-replaced-") })
    }

    @Test func unsupportedTrashStillOffersTheLocalJobFallback() throws {
        let scratch = try Scratch(), source = try scratch.file("file", "safe")
        let job = FileJob(kind: .trash, sources: [source])
        let service = TrashService { _ in throw CocoaError(.featureUnsupported) }
        job.trashItem = { try service.trash([$0]).first?.inTrash }
        _ = try job.run()
        #expect(job.untrashable == [source] && job.errors.isEmpty)
        #expect(scratch.read("file") == "safe")
    }
}
