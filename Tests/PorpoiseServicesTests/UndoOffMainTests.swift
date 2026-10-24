import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Undo of a move between volumes copies the data back: it runs off the main thread as an Activity (W-236, W-235 #10).
@Suite(.serialized, .isolatedSettings) @MainActor struct UndoOffMainTests {
    @Test func undoingAMoveBetweenVolumesRunsAsAnActivity() async throws {
        let s = try Scratch()
        let original = try s.file("a/report.txt", "report")
        let moved = s.path("b/report.txt")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        // The scratch folder is on one volume: this move counts as one between two.
        let real = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in true }
        defer { FileOperationsController.copiesData = real }
        let ui = ScriptedUI()
        let c = makeController(ui)
        c.pushUndo(.moved([(from: original, to: moved)]))
        c.undo(window: nil)
        // Off its stack and running, the main thread free.
        #expect(!c.canUndo && !c.canRedo)
        let activity = try #require(c.activities.last)
        #expect(activity.kind == .move && !activity.state.isEnded)
        #expect(await eventually { activity.state == .completed && c.canRedo })
        #expect(FileManager.default.fileExists(atPath: original.path) && !FileManager.default.fileExists(atPath: moved.path))
        // Redo the same way, and an undo meanwhile waits its turn behind it.
        c.redo(window: nil)
        #expect(await eventually { c.canUndo && FileManager.default.fileExists(atPath: moved.path) })
    }

    @Test func aFailedUndoBetweenVolumesGoesBackOnItsStack() async throws {
        let s = try Scratch()
        let gone = s.path("gone.txt"), there = s.path("elsewhere/gone.txt")
        let real = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in true }
        defer { FileOperationsController.copiesData = real }
        let ui = ScriptedUI()
        let c = makeController(ui)
        c.pushUndo(.moved([(from: gone, to: there)]))
        c.undo(window: nil)
        let activity = try #require(c.activities.last)
        #expect(await eventually { activity.state == .failed && c.canUndo })
        #expect(!activity.errors.isEmpty)
    }

    @Test func aMoveWithinAVolumeIsUndoneAtOnce() throws {
        let s = try Scratch()
        let original = try s.file("x.txt", "x"), moved = s.path("y.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(!FileOperationsController.movesBetweenVolumes(.moved([(from: original, to: moved)])))
        let c = makeController(ScriptedUI())
        c.pushUndo(.moved([(from: original, to: moved)]))
        c.undo(window: nil)
        #expect(FileManager.default.fileExists(atPath: original.path) && c.canRedo && c.activities.isEmpty)
    }
}
