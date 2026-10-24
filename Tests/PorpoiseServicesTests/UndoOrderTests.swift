import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// An action recorded while an undo is still running (CR-10): the undo's result neither offers a stale Redo nor
/// lands above the newer action, and nothing else is undone until it's done.
@Suite(.serialized, .isolatedSettings) @MainActor struct UndoOrderTests {
    @Test func anActionRecordedDuringAnUndoClearsItsRedo() async throws {
        let s = try Scratch()
        let original = s.path("a/report.txt"), moved = try s.file("b/report.txt", "report")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let real = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in true }
        defer { FileOperationsController.copiesData = real }
        let c = makeController(ScriptedUI())
        c.pushUndo(.moved([(from: original, to: moved)]))
        c.undo(window: nil)
        #expect(!c.canUndo && !c.canRedo)
        let newer = s.path("new.txt")
        c.pushUndo(.created([newer]))
        // Still running: nothing else is undone meanwhile.
        c.undo(window: nil)
        let activity = try #require(c.activities.last)
        #expect(await eventually { activity.state == .completed && c.canUndo })
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!c.canRedo)
        #expect(c.undoStack.count == 1)
        guard case .created(let urls)? = c.undoStack.last else { Issue.record("the newer action isn't on top"); return }
        #expect(urls == [newer])
    }

    @Test func aFailedUndoGoesBackBelowAnActionRecordedMeanwhile() async throws {
        let s = try Scratch()
        let gone = s.path("gone.txt"), there = s.path("elsewhere/gone.txt")
        let real = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in true }
        defer { FileOperationsController.copiesData = real }
        let c = makeController(ScriptedUI())
        c.pushUndo(.moved([(from: gone, to: there)]))
        c.undo(window: nil)
        let newer = s.path("new.txt")
        c.pushUndo(.created([newer]))
        let activity = try #require(c.activities.last)
        #expect(await eventually { activity.state == .failed && c.canUndo })
        #expect(c.undoStack.count == 2)
        guard case .created(let urls)? = c.undoStack.last, case .moved? = c.undoStack.first else {
            Issue.record("the failed undo went back above the newer action"); return
        }
        #expect(urls == [newer])
    }

    @Test func aRedoneRecordGoesBelowAnActionRecordedMeanwhile() async throws {
        let s = try Scratch()
        let here = try s.file("a/report.txt", "report"), there = s.path("b/report.txt")
        try FileManager.default.createDirectory(at: there.deletingLastPathComponent(), withIntermediateDirectories: true)
        let real = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in true }
        defer { FileOperationsController.copiesData = real }
        let c = makeController(ScriptedUI())
        // A move to `here` undone already: Redo moves the file there again, off the main thread.
        c.redoStack = [.moved([(from: there, to: here)])]
        c.redo(window: nil)
        #expect(!c.canUndo && !c.canRedo)
        let newer = s.path("new.txt")
        c.pushUndo(.created([newer]))
        let activity = try #require(c.activities.last)
        #expect(await eventually { activity.state == .completed && c.undoStack.count == 2 })
        #expect(FileManager.default.fileExists(atPath: there.path))
        guard case .created(let urls)? = c.undoStack.last, case .moved? = c.undoStack.first else {
            Issue.record("the redone record went above the newer action"); return
        }
        #expect(urls == [newer])
    }
}
