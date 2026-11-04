import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct PartialUndoTests {
    @Test(arguments: ["move", "trash", "batch"])
    func failedRollbackRetainsOnlyValidHistory(kind: String) throws {
        let s = try Scratch("partial-undo")
        let a = s.path("original/a"), b = try s.file("original/b", "occupied")
        let movedA = try s.file("moved/a", "a"), movedB = try s.file("moved/b", "b")
        let pairs = [(from: b, to: movedB), (from: a, to: movedA)]
        let record: UndoRecord
        switch kind {
        case "trash": record = .trashed(pairs.map { (original: $0.from, inTrash: $0.to) })
        case "batch": record = .batchRenamed(pairs.map { RenameMove(from: $0.from, to: $0.to) })
        default: record = .moved(pairs)
        }
        var failure: FileActions.PartialUndoError?
        do {
            _ = try FileActions.undo(record) { from, to in
                try FileManager.default.moveItem(at: from, to: to)
                if from == movedA { try Data("arrival".utf8).write(to: movedA, options: .withoutOverwriting) }
            }
            Issue.record("Expected the interrupted rollback to fail")
        } catch let error as FileActions.PartialUndoError { failure = error }
        let partial = try #require(failure)
        #expect(s.read("original/a") == "a" && s.read("moved/a") == "arrival")
        #expect(s.read("original/b") == "occupied" && s.read("moved/b") == "b")
        #expect(partial.localizedDescription.contains(a.path) && partial.localizedDescription.contains(movedA.path))
        let remaining = try #require(partial.remaining), inverse = try #require(partial.inverse)
        switch remaining {
        case .moved(let values): #expect(values.count == 1 && values[0].from == b)
        case .trashed(let values): #expect(values.count == 1 && values[0].original == b)
        case .batchRenamed(let values): #expect(values.count == 1 && values[0].from == b)
        default: Issue.record("Unexpected remaining record")
        }
        try FileManager.default.removeItem(at: b)
        _ = try FileActions.undo(remaining)
        #expect(s.read("original/b") == "b")
        try FileManager.default.removeItem(at: movedA)
        _ = try FileActions.undo(inverse)
        #expect(s.read("moved/a") == "a" && !FileJob.itemExists(at: a))
    }

    @Test func aReplacedRollbackSourceIsOmittedFromAutomaticHistory() throws {
        let s = try Scratch("changed-rollback-source")
        let a = s.path("original/a"), b = try s.file("original/b", "occupied")
        let movedA = try s.file("moved/a", "a"), movedB = try s.file("moved/b", "b")
        do {
            _ = try FileActions.undo(.moved([(from: b, to: movedB), (from: a, to: movedA)])) { from, to in
                if from == movedB {
                    try FileManager.default.removeItem(at: a)
                    try Data("new occupant".utf8).write(to: a, options: .withoutOverwriting)
                }
                if from == a { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("Expected failed rollback")
        } catch let error as FileActions.PartialUndoError {
            #expect(error.inverse == nil)
            guard case .moved(let rest)? = error.remaining else { Issue.record("Missing pending B"); return }
            #expect(rest.count == 1 && rest[0].from == b)
        }
        #expect(s.read("original/a") == "new occupant" && s.read("moved/b") == "b")
    }

    @Test func aPartiallyRolledBackRenameCycleRequiresManualReview() throws {
        let s = try Scratch("partial-cycle")
        let a = try s.file("a", "original b"), b = try s.file("b", "original a"), temporary = s.path("temporary")
        let steps = [RenameMove(from: a, to: temporary), RenameMove(from: b, to: a), RenameMove(from: temporary, to: b)]
        do {
            _ = try FileActions.undo(.batchRenamed(steps)) { from, to in
                try FileManager.default.moveItem(at: from, to: to)
                if from == a { try Data("arrival".utf8).write(to: a, options: .withoutOverwriting) }
            }
            Issue.record("Expected failed cycle rollback")
        } catch let error as FileActions.PartialUndoError {
            #expect(error.remaining == nil && error.inverse == nil)
            #expect(Set(error.paths) == Set([a, b, temporary]))
        }
        #expect(s.read("a") == "arrival" && s.read("b") == "original b" && s.read("temporary") == "original a")
    }

    @Test func aFailedMoveThatCopiedDataNeedsManualReviewInsteadOfAnAutomaticRetry() throws {
        let s = try Scratch("partial-move")
        let original = s.path("original/a"), moved = try s.file("moved/a", "a")
        do {
            _ = try FileActions.undo(.moved([(from: original, to: moved)])) { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                throw CocoaError(.fileWriteNoPermission)
            }
            Issue.record("Expected a copy-then-fail move")
        } catch let error as FileActions.PartialUndoError {
            #expect(error.remaining == nil && error.inverse == nil)
            #expect(Set(error.paths) == Set([original, moved]))
        }
        #expect(s.read("original/a") == "a" && s.read("moved/a") == "a")
    }

    @Test func trashRollbackFailureRetainsOriginsAndCreationUndoSubsets() throws {
        let s = try Scratch("partial-trash")
        let a = try s.file("original/a", "a"), b = try s.file("original/b", "b")
        let trashedA = s.path("trash/a")
        try FileManager.default.createDirectory(at: trashedA.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            _ = try FileActions.undo(
                .created([a, b]),
                trash: { urls in
                    try FileActions.trashAll(urls) { url in
                        if url == b { throw CocoaError(.fileWriteNoPermission) }
                        try FileManager.default.moveItem(at: url, to: trashedA)
                        try Data("arrival".utf8).write(to: a, options: .withoutOverwriting)
                        return trashedA
                    }
                })
            Issue.record("Expected failed Trash rollback")
        } catch let error as FileActions.PartialUndoError {
            guard case .created(let remaining)? = error.remaining, case .trashed(let retained)? = error.inverse else {
                Issue.record("Missing reconciled Trash records"); return
            }
            #expect(remaining == [b])
            #expect(retained.count == 1 && retained[0].original == a && retained[0].inTrash == trashedA)
            #expect(error.cause is FileActions.PartialTrashError)
            try FileManager.default.removeItem(at: a)
            _ = try FileActions.undo(try #require(error.inverse))
        }
        #expect(s.read("original/a") == "a" && s.read("original/b") == "b")
    }

    @Test func successfulRollbackThrowsOriginalErrorAndKeepsWholeRecordRetryable() throws {
        let s = try Scratch("undo-rollback")
        let a = s.path("original/a"), b = try s.file("original/b", "occupied")
        let movedA = try s.file("moved/a", "a"), movedB = try s.file("moved/b", "b")
        let record = UndoRecord.moved([(from: b, to: movedB), (from: a, to: movedA)])
        var moves = 0
        do {
            _ = try FileActions.undo(record) { from, to in
                moves += 1
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("Expected occupied original name")
        } catch { #expect(!(error is FileActions.PartialUndoError)) }
        #expect(moves == 3, "A move, the failing B move, and a real rollback must all run")
        #expect(s.read("moved/a") == "a" && s.read("moved/b") == "b" && !FileJob.itemExists(at: a))
        try FileManager.default.removeItem(at: b)
        _ = try FileActions.undo(record)
        #expect(s.read("original/a") == "a" && s.read("original/b") == "b")
    }
}
