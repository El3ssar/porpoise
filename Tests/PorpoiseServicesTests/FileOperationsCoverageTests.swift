import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A user who confirms everything and ticks "Do not ask again". Never agrees to authenticate.
private final class DontAskAgainUI: FileOperationsUI {
    private(set) var questions: [PorpoiseServices.Confirmation] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    func confirm(_ question: PorpoiseServices.Confirmation, window: AnyObject?) -> (confirmed: Bool, dontAskAgain: Bool) {
        questions.append(question)
        return question.confirmTitle == "Authenticate" ? (false, false) : (true, true)
    }

    func showErrors(_ errors: [String], window: AnyObject?) { Issue.record("Unexpected errors: \(errors)") }
    func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer { ConflictAnswer(.cancel) }
    func jobStarted(_ job: FileJob) {}
    func jobProgressed(_ job: FileJob, _ progress: JobProgress) {}
    func showAuthorizationError(_ message: String) {}

    func jobFinished(_ job: FileJob) {
        let w = waiting
        waiting = [:]
        w.values.forEach { $0.resume() }
    }

    /// Waits for the next job to finish; fails the test after `timeout` instead of hanging.
    @MainActor func nextJobFinished(timeout: TimeInterval = 20) async {
        let id = UUID()
        await withCheckedContinuation { c in
            waiting[id] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
                guard let c = waiting.removeValue(forKey: id) else { return }
                Issue.record("No job finished within \(Int(timeout)) seconds")
                c.resume()
            }
        }
    }
}

/// FileOperationsController's questions ("Do not ask again", emptying a Trash, volumes without one), conflicts
/// without anyone to ask, authentication for several items, and putting items back where they can't be listed.
@MainActor @Suite(.isolatedSettings) struct FileOperationsCoverageTests {
    let fm = FileManager.default

    // MARK: "Do not ask again"

    @Test func deletingWithDoNotAskAgainStopsAsking() async throws {
        let s = try Scratch()
        let f = try s.file("old.txt")
        let ui = DontAskAgainUI()
        let c = FileOperationsController()
        c.ui = ui
        #expect(Settings.shared.confirmDelete)
        c.delete([f], window: nil)
        await ui.nextJobFinished()
        #expect(!Settings.shared.confirmDelete)
        #expect(s.listing().isEmpty && ui.questions.count == 1)
    }

    @Test func trashingWithDoNotAskAgainStopsAsking() async throws {
        let s = try Scratch()
        let disk = try DiskImage(in: s)
        let f = disk.volume.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: f)
        Settings.shared.confirmTrash = true
        let ui = DontAskAgainUI()
        let c = FileOperationsController()
        c.ui = ui
        c.trash([f], window: nil)
        await ui.nextJobFinished()
        #expect(!Settings.shared.confirmTrash)
        #expect(!FileJob.itemExists(at: f))
        #expect(ui.questions.map(\.message) == ["Do you really want to move “notes.txt” to the Trash?"])
    }

    // MARK: Emptying the Trash

    @Test func emptyingAskedFirstAndDecliningKeepsEverything() throws {
        let s = try Scratch()
        try s.file("trash1/a.txt"); try s.folder("trash1/folder"); try s.folder("trash2")
        let ui = ScriptedUI(confirms: false)
        makeController(ui).emptyTrash([s.path("trash1"), s.path("trash2"), s.path("missing")], window: nil)
        #expect(ui.questions.map(\.message) == ["Do you really want to empty the Trash? All items will be deleted."])
        #expect(ui.questions.first?.suppressible == true && ui.questions.first?.destructive == true)
        #expect(s.listing("trash1") == ["a.txt", "folder"] && ui.finishedJobs.isEmpty)
    }

    @Test func emptyingDeletesEveryTrashFoldersItems() async throws {
        let s = try Scratch()
        try s.file("trash1/a.txt"); try s.file("trash1/folder/inner.txt"); try s.file("trash2/b.txt")
        let ui = DontAskAgainUI()
        let c = FileOperationsController()
        c.ui = ui
        c.emptyTrash([s.path("trash1"), s.path("trash2")], window: nil)
        await ui.nextJobFinished()
        #expect(s.listing("trash1").isEmpty && s.listing("trash2").isEmpty)
        #expect(!Settings.shared.confirmEmptyTrash)

        // Not asked any more.
        try s.file("trash1/c.txt")
        let quiet = ScriptedUI()
        let c2 = makeController(quiet)
        c2.emptyTrash([s.path("trash1")], window: nil)
        await quiet.nextJobFinished()
        #expect(quiet.questions.isEmpty && s.listing("trash1").isEmpty)
    }

    @Test func anEmptyTrashIsLeftAlone() throws {
        let s = try Scratch()
        try s.folder("trash")
        let ui = ScriptedUI()
        makeController(ui).emptyTrash([s.path("trash")], window: nil)
        #expect(ui.questions.isEmpty && ui.finishedJobs.isEmpty)
    }

    // MARK: Volumes without a Trash

    @Test func itemsThatCantBeTrashedAreDeletedAfterAsking() async throws {
        let s = try Scratch()
        let one = try s.file("one.txt")
        let ui = ScriptedUI()
        let c = makeController(ui)
        c.offerDelete([one], window: nil)
        await ui.nextJobFinished()
        #expect(!FileJob.itemExists(at: one))
        #expect(ui.questions.map(\.message) == ["“one.txt” can't be moved to the Trash. Do you want to delete it immediately?"])
        #expect(ui.questions.first?.destructive == true)
    }

    @Test func decliningKeepsItemsThatCantBeTrashed() throws {
        let s = try Scratch()
        let a = try s.file("a.txt"), b = try s.file("b.txt")
        let ui = ScriptedUI(confirms: false)
        makeController(ui).offerDelete([a, b], window: nil)
        #expect(ui.questions.map(\.message) == ["These 2 items can't be moved to the Trash. Do you want to delete them immediately?"])
        #expect(s.listing() == ["a.txt", "b.txt"] && ui.finishedJobs.isEmpty)
    }

    // MARK: Jobs

    /// Without a UI (the app not connected yet) nobody can answer a conflict: the job cancels, nothing is replaced.
    @Test func withoutAUIConflictsCancel() async throws {
        let s = try Scratch()
        let src = try s.file("x.txt", "new")
        try s.file("dest/x.txt", "old")
        let c = FileOperationsController()
        let results = await c.perform(.copy, [src], to: s.path("dest"))
        #expect(results.isEmpty)
        #expect(s.read("dest/x.txt") == "old")
    }

    @Test func failuresAreShown() async throws {
        let s = try Scratch()
        let ui = ScriptedUI()
        let c = makeController(ui)
        let results = await c.perform(.copy, [s.path("gone.txt")], to: try s.folder("dest"))
        #expect(results.isEmpty)
        #expect(ui.errors.count == 1 && ui.errors.first?.contains("gone.txt") == true)
    }

    // MARK: Authentication

    @Test func authenticatingForSeveralItemsNamesThem() throws {
        let s = try Scratch()
        let items = try (1...8).map { try s.file("f\($0).txt") }
        let ui = ScriptedUI()
        let c = makeController(ui)
        #expect(!c.authorize(verb: "delete", items: items, commands: [["/bin/rm", "--", items[0].path]], window: nil))
        let q = try #require(ui.questions.first)
        #expect(q.message == "Porpoise needs your permission to delete 8 items.")
        #expect(q.detail.hasPrefix("“f1.txt”, “f2.txt”, “f3.txt”, “f4.txt”, “f5.txt”, “f6.txt”\n\n"))
        #expect(!q.detail.contains("f7.txt"))
        #expect(s.listing().count == 8)
        // Nothing to run: nothing is asked.
        #expect(!c.authorize(verb: "delete", items: items, commands: [], window: nil))
        #expect(ui.questions.count == 1)
    }

    // MARK: Restoring from the Trash

    /// The original folder can be written to but not listed: the restored item still gets a free name.
    @Test func restoringIntoAFolderThatCannotBeListed() throws {
        let s = try Scratch()
        let trashed = try s.file("fake-trash/report.txt", "restored")
        try s.file("docs/report.txt", "already here")
        let docs = s.path("docs")
        let ui = ScriptedUI()
        let c = makeController(ui)
        c.recordTrash(.trashed([(original: s.path("docs/report.txt"), inTrash: trashed)]))
        chmod(docs.path, 0o300)
        defer { chmod(docs.path, 0o755) }
        #expect(c.restore([trashed], window: nil).isEmpty)
        chmod(docs.path, 0o755)
        #expect(s.listing("docs") == ["report (1).txt", "report.txt"])
        #expect(s.read("docs/report (1).txt") == "restored" && ui.errors.isEmpty)
        #expect(c.undoTitle == "Undo: Move")
    }

    @Test func restoringSomethingGoneFromTheTrashShowsTheError() throws {
        let s = try Scratch()
        let trashed = try s.file("fake-trash/gone.txt")
        let ui = ScriptedUI()
        let c = makeController(ui)
        c.recordTrash(.trashed([(original: s.path("docs/gone.txt"), inTrash: trashed)]))
        try fm.removeItem(at: trashed)
        #expect(c.restore([trashed], window: nil).isEmpty)
        #expect(ui.errors.count == 1)
        #expect(c.undoStack.isEmpty)
    }
}
