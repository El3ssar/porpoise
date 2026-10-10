import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// Moving to the Trash, Put Back and undoing what goes through the Trash. Everything happens on an attached disk
/// image, whose own Trash (.Trashes/<uid>) takes the items: nothing ever reaches the user's ~/.Trash.
@Suite final class TrashDiskImageTests {
    let scratch: Scratch
    let disk: DiskImage
    let ui = ScriptedUI()
    let controller: FileOperationsController

    /// Off the main actor, so the tests' disk images are created and attached side by side.
    init() async throws {
        scratch = try Scratch()
        disk = try DiskImage(in: scratch)
        controller = makeController(ui)
    }

    private func file(_ name: String, _ contents: String = "x") throws -> URL {
        let u = disk.volume.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: u)
        return u
    }

    private var volumeTrash: URL { disk.volume.appendingPathComponent(".Trashes/\(getuid())") }

    /// Present in the disk image's Trash (which can be checked item by item, not listed, without Full Disk Access).
    private func isInVolumeTrash(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath() == volumeTrash.resolvingSymlinksInPath() && FileJob.itemExists(at: url)
    }

    /// Where the last trash put each item, from the undo record.
    private var lastTrashed: [(original: URL, inTrash: URL)] {
        guard case .trashed(let pairs)? = controller.undoStack.last else { return [] }
        return pairs
    }

    @MainActor private func trash(_ urls: [URL]) async {
        controller.trash(urls, window: nil)
        await ui.nextJobFinished()
    }

    @MainActor @Test func trashedItemsLandInTheVolumesOwnTrash() async throws {
        let notes = try file("notes.txt"), project = try file("project/main.swift")
        await trash([notes, project.deletingLastPathComponent()])
        #expect(!FileJob.itemExists(at: notes) && !FileJob.itemExists(at: disk.volume.appendingPathComponent("project")))
        #expect(lastTrashed.map(\.original) == [notes, project.deletingLastPathComponent()])
        #expect(lastTrashed.allSatisfy { isInVolumeTrash($0.inTrash) })
        #expect(controller.undoTitle == "Undo: Move to Trash")
        #expect(ui.errors.isEmpty && ui.questions.isEmpty)
    }

    @MainActor @Test func putBackRestoresTheOriginalLocationsEvenOfRemovedFolders() async throws {
        let deep = try file("a/b/deep.txt", "deep")
        await trash([deep])
        try FileManager.default.removeItem(at: disk.volume.appendingPathComponent("a"))
        let unknown = controller.restore(lastTrashed.map(\.inTrash), window: nil)
        #expect(unknown.isEmpty)
        #expect(try String(contentsOf: deep, encoding: .utf8) == "deep")
        #expect(controller.undoTitle == "Undo: Move")
    }

    @MainActor @Test func putBackPicksANewNameWhenTheOriginalIsTaken() async throws {
        let f = try file("report.txt", "first")
        await trash([f])
        let inTrash = lastTrashed.map(\.inTrash)
        try Data("second".utf8).write(to: f)
        _ = controller.restore(inTrash, window: nil)
        #expect(try String(contentsOf: f, encoding: .utf8) == "second")
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("report (1).txt"), encoding: .utf8) == "first")
    }

    @MainActor @Test func putBackOfAnItemTrashedElsewhereReportsItAsUnknown() async throws {
        let f = try file("from-finder.txt")
        var out: NSURL?
        try FileManager.default.trashItem(at: f, resultingItemURL: &out)
        let inTrash = try #require(out as URL?)
        #expect(controller.restore([inTrash], window: nil) == [inTrash])
        #expect(FileJob.itemExists(at: inTrash) && !controller.canUndo)
    }

    @MainActor @Test func originsOfItemsGoneFromTheTrashAreForgotten() async throws {
        await trash([try file("one")])
        let first = lastTrashed[0].inTrash
        try FileManager.default.removeItem(at: first)
        await trash([try file("two")])
        let origins = Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:]
        #expect(origins[lastTrashed[0].inTrash.path] != nil && origins[first.path] == nil)
    }

    @MainActor @Test func undoAndRedoOfTrash() async throws {
        let f = try file("draft.txt", "draft")
        await trash([f])
        controller.undo(window: nil)
        #expect(try String(contentsOf: f, encoding: .utf8) == "draft")
        #expect(controller.redoTitle == "Redo: Move")
        controller.redo(window: nil)
        #expect(!FileJob.itemExists(at: f))
        #expect(isInVolumeTrash(volumeTrash.appendingPathComponent("draft.txt")))
        #expect(controller.canUndo && !controller.canRedo)
    }

    @MainActor @Test func aLockedFileYouOwnIsUnlockedAndTrashed() async throws {
        let f = try file("locked.txt")
        #expect(chflags(f.path, UInt32(UF_IMMUTABLE)) == 0)
        await trash([f])
        #expect(!FileJob.itemExists(at: f))
        #expect(lastTrashed.map(\.original) == [f])
        #expect(!ui.questions.contains { $0.confirmTitle == "Authenticate" })
        // Put Back knows where it came from, as for any other item.
        #expect(controller.restore(lastTrashed.map(\.inTrash), window: nil).isEmpty)
        #expect(FileJob.itemExists(at: f))
    }

    @MainActor @Test func unlockingALinkLeavesTheFileItPointsToAlone() async throws {
        // A link in a read-only folder can't be trashed; unlocking it must not unlock or open up its target.
        let target = try scratch.file("precious.txt", "keep")
        chmod(target.path, 0o444)
        #expect(chflags(target.path, UInt32(UF_IMMUTABLE)) == 0)
        let folder = disk.volume.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: target)
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }
        await trash([folder.appendingPathComponent("link")])
        var st = stat()
        #expect(stat(target.path, &st) == 0)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0, "the target was unlocked")
        #expect(st.st_mode & 0o777 == 0o444, "the target was made writable")
    }

    @MainActor @Test func confirmingTrashAsksFirstAndDecliningKeepsTheItems() async throws {
        let f = try file("keep.txt")
        ui.confirms = false
        Settings.shared.confirmTrash = true
        controller.trash([f], window: nil)
        Settings.shared.confirmTrash = false
        #expect(ui.questions.map(\.message) == ["Do you really want to move “keep.txt” to the Trash?"])
        #expect(ui.finishedJobs.isEmpty && FileJob.itemExists(at: f))
    }

    @MainActor @Test func appsThatArePartOfMacOSAreNotTrashed() async throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let f = try file("mine.txt")
        await trash([calculator, f])
        #expect(ui.questions.map(\.message) == ["“Calculator” is part of macOS and can't be moved to the Trash."])
        #expect(lastTrashed.map(\.original) == [f])
        #expect(FileJob.itemExists(at: calculator))
    }

    @MainActor @Test func remoteItemsInTheSelectionAreDeletedAfterAskingAndLocalOnesTrashed() async throws {
        let f = try file("local.txt")
        controller.trash([URL(string: "unknown://host/remote.txt")!, f], window: nil)
        #expect(ui.questions.map(\.message) == ["Permanently delete “remote.txt”?"])
        await ui.nextJobFinished()
        if ui.finishedJobs.count < 2 { await ui.nextJobFinished() }
        #expect(lastTrashed.map(\.original) == [f])
        #expect(ui.errors.count == 1)   // the remote one: nothing provides "unknown://"
    }

    // MARK: Undo of things that go back through the Trash

    @MainActor @Test func anUndoThatCannotTrashEverythingPutsBackWhatItTrashed() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        controller.pushUndo(.created([a, b]))
        #expect(chflags(b.path, UInt32(UF_IMMUTABLE)) == 0)
        controller.undo(window: nil)
        #expect(FileJob.itemExists(at: a) && FileJob.itemExists(at: b))
        #expect(ui.errors.count == 1 && controller.undoTitle == "Undo: Create")
        #expect(!FileJob.itemExists(at: volumeTrash.appendingPathComponent("a.txt")))
    }

    @MainActor @Test func undoingACopyTrashesTheCopyAndRedoBringsItBack() async throws {
        let original = try file("src/photo.jpg", "pixels")
        let dst = disk.volume.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        _ = await controller.perform(.copy, [original], to: dst)
        let copy = dst.appendingPathComponent("photo.jpg")
        #expect(controller.undoTitle == "Undo: Create")

        controller.undo(window: nil)
        #expect(!FileJob.itemExists(at: copy) && FileJob.itemExists(at: original))
        #expect(isInVolumeTrash(volumeTrash.appendingPathComponent("photo.jpg")))

        controller.redo(window: nil)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "pixels")
        #expect(controller.undoTitle == "Undo: Move")
    }

    @MainActor @Test func undoingANewFolderTrashesIt() async throws {
        let folder = try FileActions.makeFolder(named: "New Folder", in: disk.volume)
        controller.pushUndo(.created([folder]))
        controller.undo(window: nil)
        #expect(!FileJob.itemExists(at: folder))
        #expect(controller.redoTitle == "Redo: Move to Trash")
    }
}
