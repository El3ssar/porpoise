import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The controller's undo and redo stacks. Undoing anything that goes through the Trash is in TrashDiskImageTests.
@MainActor @Suite(.isolatedSettings) struct UndoRedoTests {
    @Test func undoAndRedoOfAMove() async throws {
        let s = try Scratch()
        let a = try s.file("inbox/a.txt", "a"), b = try s.file("inbox/b.txt", "b")
        let ui = ScriptedUI()
        let c = makeController(ui)
        _ = await c.perform(.move, [a, b], to: try s.folder("archive"))
        #expect(c.undoTitle == "Undo: Move" && c.redoTitle == nil)

        c.undo(window: nil)
        #expect(s.listing("inbox") == ["a.txt", "b.txt"] && s.listing("archive").isEmpty)
        #expect(c.redoTitle == "Redo: Move" && !c.canUndo)

        c.redo(window: nil)
        #expect(s.listing("archive") == ["a.txt", "b.txt"] && s.listing("inbox").isEmpty)
        #expect(c.canUndo && !c.canRedo)
        #expect(ui.errors.isEmpty)
    }

    @Test func undoAndRedoOfARename() throws {
        let s = try Scratch()
        let old = try s.file("draft.txt", "text")
        let new = try FileActions.rename(old, to: "final.txt")
        let c = makeController(ScriptedUI())
        c.pushUndo(.renamed(from: old, to: new))
        #expect(c.undoTitle == "Undo: Rename")
        c.undo(window: nil)
        #expect(s.listing() == ["draft.txt"])
        c.redo(window: nil)
        #expect(s.listing() == ["final.txt"])
        c.undo(window: nil)
        #expect(s.read("draft.txt") == "text")
    }

    @Test func undoingACaseOnlyRenameRestoresTheCase() throws {
        let s = try Scratch()
        let old = try s.file("readme.md")
        let new = try FileActions.rename(old, to: "README.md")
        #expect(s.listing() == ["README.md"])
        let c = makeController(ScriptedUI())
        c.pushUndo(.renamed(from: old, to: new))
        c.undo(window: nil)
        #expect(s.listing() == ["readme.md"])
    }

    @Test func aFailedUndoStaysOnTheStackForAnotherTry() async throws {
        let s = try Scratch()
        let f = try s.file("src/plan.txt", "plan")
        let ui = ScriptedUI()
        let c = makeController(ui)
        _ = await c.perform(.move, [f], to: try s.folder("dst"))
        try s.file("src/plan.txt", "someone else's")  // the original name is taken meanwhile

        c.undo(window: nil)
        #expect(ui.errors.count == 1)
        #expect(c.undoTitle == "Undo: Move" && !c.canRedo)
        #expect(s.read("src/plan.txt") == "someone else's" && s.read("dst/plan.txt") == "plan")

        try FileManager.default.removeItem(at: s.path("src/plan.txt"))
        c.undo(window: nil)
        #expect(s.read("src/plan.txt") == "plan" && c.canRedo)
    }

    @Test func aFailedRedoStaysOnTheStackToo() async throws {
        let s = try Scratch()
        let f = try s.file("src/plan.txt", "plan")
        let ui = ScriptedUI()
        let c = makeController(ui)
        _ = await c.perform(.move, [f], to: try s.folder("dst"))
        c.undo(window: nil)
        try s.file("dst/plan.txt", "squatter")
        c.redo(window: nil)
        #expect(ui.errors.count == 1 && c.redoTitle == "Redo: Move")
        #expect(s.read("src/plan.txt") == "plan")
    }

    @Test func aNewActionClearsRedo() async throws {
        let s = try Scratch()
        let ui = ScriptedUI()
        let c = makeController(ui)
        _ = await c.perform(.move, [try s.file("a")], to: try s.folder("dst"))
        c.undo(window: nil)
        #expect(c.canRedo)
        _ = await c.perform(.move, [try s.file("b")], to: s.path("dst"))
        #expect(!c.canRedo && c.undoTitle == "Undo: Move")
    }

    @Test func undoNotifiesTheFoldersItTouched() async throws {
        let s = try Scratch()
        let c = makeController(ScriptedUI())
        _ = await c.perform(.move, [try s.file("src/a")], to: try s.folder("dst"))
        var paths: Set<String> = []
        let token = NotificationCenter.default.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: nil) {
            paths.formUnion($0.userInfo?["paths"] as? Set<String> ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        c.undo(window: nil)
        #expect(paths.isSuperset(of: [s.path("src").path, s.path("dst").path]))
    }

    @Test func aCancelledOrEmptyJobLeavesNothingToUndo() async throws {
        let s = try Scratch()
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.skip)])
        let c = makeController(ui)
        try s.file("dst/a", "old")
        _ = await c.perform(.copy, [try s.file("src/a", "new")], to: s.path("dst"))
        #expect(!c.canUndo && c.undoTitle == nil)
    }
}
