import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// Copying and moving into a folder that already has items of the same names, answered through the conflict dialog.
@MainActor @Suite struct FileOperationsConflictTests {
    @Test func skipLeavesBothItemsAlone() async throws {
        let s = try Scratch()
        let src = try s.file("src/notes.txt", "new")
        try s.file("dst/notes.txt", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.skip)])
        let results = await makeController(ui).perform(.move, [src], to: s.path("dst"))
        #expect(results.isEmpty)
        #expect(s.read("src/notes.txt") == "new" && s.read("dst/notes.txt") == "old")
        #expect(ui.conflicts.map(\.destination.name) == ["notes.txt"])
    }

    @Test func replaceOverwritesTheFileAndLeavesNoStagingCopy() async throws {
        let s = try Scratch()
        let src = try s.file("src/notes.txt", "new")
        try s.file("dst/notes.txt", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.overwrite)])
        let results = await makeController(ui).perform(.copy, [src], to: s.path("dst"))
        #expect(results == [s.path("dst/notes.txt")])
        #expect(s.read("dst/notes.txt") == "new" && s.read("src/notes.txt") == "new")
        #expect(s.listing("dst") == ["notes.txt"])
    }

    @Test func keepBothUsesTheSuggestedName() async throws {
        let s = try Scratch()
        let src = try s.file("src/notes.txt", "new")
        try s.file("dst/notes.txt", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.rename("notes (1).txt"))])
        _ = await makeController(ui).perform(.copy, [src], to: s.path("dst"))
        #expect(ui.conflicts.first?.suggestedName == "notes (1).txt")
        #expect(s.listing("dst") == ["notes (1).txt", "notes.txt"])
        #expect(s.read("dst/notes (1).txt") == "new" && s.read("dst/notes.txt") == "old")
    }

    @Test func keepBothForAllNumbersEachItem() async throws {
        let s = try Scratch()
        let sources = try ["a.txt", "b.txt"].map { try s.file("src/\($0)", "new \($0)") }
        try s.file("dst/a.txt", "old"); try s.file("dst/b.txt", "old")
        try s.file("dst/a (1).txt", "older")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.rename("a (2).txt"), applyToAll: true)])
        _ = await makeController(ui).perform(.copy, sources, to: s.path("dst"))
        #expect(ui.conflicts.count == 1)
        #expect(s.read("dst/a (2).txt") == "new a.txt")
        #expect(s.read("dst/b (1).txt") == "new b.txt")   // the suggestion for b, not a's name
        #expect(s.read("dst/a (1).txt") == "older")
    }

    @Test func mergingFoldersKeepsWhatWasOnlyInTheDestination() async throws {
        let s = try Scratch()
        try s.file("src/photos/2024/a.jpg", "a")
        try s.file("src/photos/top.jpg", "top")
        try s.file("dst/photos/2024/b.jpg", "b")
        try s.file("dst/photos/mine.jpg", "mine")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.writeInto, applyToAll: true)])
        _ = await makeController(ui).perform(.move, [s.path("src/photos")], to: s.path("dst"))
        #expect(s.listing("dst/photos") == ["2024", "mine.jpg", "top.jpg"])
        #expect(s.listing("dst/photos/2024") == ["a.jpg", "b.jpg"])
        #expect(s.listing("src").isEmpty)
        #expect(ui.conflicts.count == 1)   // the nested folder merged without asking again
    }

    @Test func replaceForAllAsksOnceAndReplacesEveryFile() async throws {
        let s = try Scratch()
        let sources = try (1...3).map { try s.file("src/f\($0)", "new") }
        for i in 1...3 { try s.file("dst/f\(i)", "old") }
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.overwrite, applyToAll: true)])
        _ = await makeController(ui).perform(.move, sources, to: s.path("dst"))
        #expect(ui.conflicts.count == 1)
        #expect((1...3).allSatisfy { s.read("dst/f\($0)") == "new" })
        #expect(s.listing("src").isEmpty)
    }

    @Test func cancelStopsBeforeTheRemainingItems() async throws {
        let s = try Scratch()
        let a = try s.file("src/a", "new"), b = try s.file("src/b", "b")
        try s.file("dst/a", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.cancel)])
        let c = makeController(ui)
        _ = await c.perform(.move, [a, b], to: s.path("dst"))
        #expect(s.listing("dst") == ["a"] && s.listing("src") == ["a", "b"])
        #expect(ui.errors.isEmpty)   // cancelling isn't an error
        #expect(!c.canUndo)
    }

    @Test func aFailedReplaceKeepsTheOriginal() async throws {
        let s = try Scratch()
        try s.file("src/report/readable", "r")
        let secret = try s.file("src/report/secret/inner", "x").deletingLastPathComponent()
        try s.file("dst/report", "the only copy")
        chmod(secret.path, 0)
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.overwrite)])
        let results = await makeController(ui).perform(.copy, [s.path("src/report")], to: s.path("dst"))
        #expect(results.isEmpty)
        #expect(s.read("dst/report") == "the only copy")
        #expect(s.listing("dst") == ["report"])
        // Not allowed to read it: offered to the administrator, who the scripted user declines.
        #expect(ui.questions.last?.confirmTitle == "Authenticate")
    }

    @Test func pastingIntoTheSameFolderMakesACopyWithoutAsking() async throws {
        let s = try Scratch()
        let f = try s.file("docs/plan.txt", "v1")
        let ui = ScriptedUI()
        let c = makeController(ui)
        let first = await c.perform(.copy, [f], to: s.path("docs"))
        let second = await c.perform(.copy, [f], to: s.path("docs"))
        #expect(first.map(\.lastPathComponent) == ["plan copy.txt"])
        #expect(second.map(\.lastPathComponent) == ["plan copy 2.txt"])
        #expect(ui.conflicts.isEmpty)
    }

    @Test func unicodeEquivalentNamesConflict() async throws {
        let s = try Scratch()
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let src = try s.file("src/\(composed)", "new")
        try s.file("dst/\(decomposed)", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.skip)])
        _ = await makeController(ui).perform(.copy, [src], to: s.path("dst"))
        // APFS treats both spellings as one name: asking is the only safe answer.
        #expect(ui.conflicts.count == 1)
        #expect(s.listing("dst").count == 1 && s.read("dst/\(decomposed)") == "old")
    }

    @Test func caseOnlyDifferentNamesConflictOnACaseInsensitiveVolume() async throws {
        let s = try Scratch()
        let src = try s.file("src/README", "new")
        try s.file("dst/readme", "old")
        let ui = ScriptedUI(conflicts: [ConflictAnswer(.overwrite)])
        _ = await makeController(ui).perform(.copy, [src], to: s.path("dst"))
        #expect(ui.conflicts.count == 1)
        #expect(s.listing("dst").count == 1 && s.read("dst/readme") == "new")
    }
}
