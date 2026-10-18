import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct AppCleanupTrashTests {
    @MainActor @Test func cancellingReviewLeavesApplicationAndRelatedFilesAlone() throws {
        let scratch = try Scratch(); let app = try scratch.folder("Example.app")
        let support = try scratch.file("support/data", "keep")
        let ui = ScriptedUI(); ui.cleanupSelection = .some(nil)
        let controller = FileOperationsController(); controller.ui = ui
        controller.trash([app], window: nil)
        #expect(ui.reviewedCleanup == [app] && ui.finishedJobs.isEmpty)
        #expect(FileJob.itemExists(at: app) && FileJob.itemExists(at: support))
    }

    @Test func reviewedSelectionUsesOnlyDiskImagesTrashAndUndoRestoresAllItems() async throws {
        let scratch = try Scratch(); let disk = try DiskImage(in: scratch)
        let app = disk.volume.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let related = disk.volume.appendingPathComponent("com.test.example.plist")
        let unselected = disk.volume.appendingPathComponent("shared-keep.plist")
        let note = disk.volume.appendingPathComponent("selected-note.txt")
        for url in [related, unselected, note] { try Data("keep".utf8).write(to: url) }
        await reviewAndUndo(app: app, related: related, unselected: unselected, note: note, volume: disk.volume)
    }

    @MainActor private func reviewAndUndo(app: URL, related: URL, unselected: URL, note: URL, volume: URL) async {
        Settings.shared.confirmTrash = true
        let ui = ScriptedUI(); ui.cleanupSelection = [related]
        let controller = FileOperationsController(); controller.ui = ui
        controller.trash([app, note], window: nil)
        await ui.nextJobFinished()
        #expect(ui.reviewedCleanup == [app, note])
        #expect(ui.questions.isEmpty && ui.errors.isEmpty)
        guard case .trashed(let pairs)? = controller.undoStack.last else { Issue.record("Missing Trash undo record"); return }
        #expect(Set(pairs.map(\.original)) == Set([app, note, related]))
        let trash = volume.appendingPathComponent(".Trashes/\(getuid())").resolvingSymlinksInPath()
        #expect(pairs.allSatisfy { $0.inTrash.deletingLastPathComponent().resolvingSymlinksInPath() == trash })
        #expect(FileJob.itemExists(at: unselected))
        controller.undo(window: nil)
        #expect([app, note, related, unselected].allSatisfy { FileJob.itemExists(at: $0) })
    }
}
