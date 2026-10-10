import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// Deleting permanently: asked first, and items you own are unlocked rather than handed to the administrator.
@MainActor @Suite struct DeleteTests {
    private func delete(_ urls: [URL], with ui: ScriptedUI) async {
        let c = makeController(ui)
        c.delete(urls, window: nil)
        await ui.nextJobFinished()
    }

    @Test func asksFirstAndDeletesFoldersWithTheirContents() async throws {
        let s = try Scratch()
        try s.file("old/a/b/c.txt")
        let ui = ScriptedUI()
        await delete([s.path("old")], with: ui)
        #expect(s.listing().isEmpty)
        #expect(ui.questions.map(\.message) == ["Do you really want to delete “old”?"])
        #expect(ui.questions.first?.destructive == true)
    }

    @Test func decliningDeletesNothing() throws {
        let s = try Scratch()
        let f = try s.file("keep.txt")
        let ui = ScriptedUI(confirms: false)
        makeController(ui).delete([f, try s.file("also.txt")], window: nil)
        #expect(ui.questions.map(\.message) == ["Do you really want to delete these 2 items?"])
        #expect(ui.finishedJobs.isEmpty && s.listing() == ["also.txt", "keep.txt"])
    }

    @Test func lockedItemsYouOwnAreUnlockedAndDeleted() async throws {
        let s = try Scratch()
        let locked = try s.file("locked.txt")
        let nested = try s.file("folder/inner/locked-too.txt")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(nested.path, UInt32(UF_IMMUTABLE)) == 0)
        let ui = ScriptedUI()
        await delete([locked, s.path("folder")], with: ui)
        #expect(s.listing().isEmpty)
        #expect(!ui.questions.contains { $0.confirmTitle == "Authenticate" })
        #expect(ui.errors.isEmpty)
    }

    @Test func readOnlyFoldersYouOwnAreMadeWritableAndDeleted() async throws {
        let s = try Scratch()
        try s.file("ro/sub/file.txt")
        chmod(s.path("ro/sub").path, 0o555)
        chmod(s.path("ro").path, 0o555)
        let ui = ScriptedUI()
        await delete([s.path("ro")], with: ui)
        #expect(s.listing().isEmpty)
        #expect(!ui.questions.contains { $0.confirmTitle == "Authenticate" })
    }

    @Test func aFileInAReadOnlyFolderNeedsTheAdministrator() async throws {
        let s = try Scratch()
        let f = try s.file("ro/file.txt")
        chmod(s.path("ro").path, 0o555)
        let ui = ScriptedUI()
        await delete([f], with: ui)
        // Unlocking the file itself doesn't help: its folder is read-only. The scripted user declines to authenticate.
        #expect(FileJob.itemExists(at: f))
        #expect(ui.questions.last?.message == "Porpoise needs your permission to delete “file.txt”.")
    }
}
