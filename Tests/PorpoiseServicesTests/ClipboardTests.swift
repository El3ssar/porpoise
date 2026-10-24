import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Cut, copy and paste through the controller's clipboard (a LocalClipboard here, the system pasteboard in the app).
@MainActor @Suite(.isolatedSettings) struct ClipboardTests {
    @Test func cutThenPasteMovesAndClearsTheClipboard() async throws {
        let s = try Scratch()
        let a = try s.file("src/a.txt", "a"), b = try s.file("src/b.txt", "b")
        let c = makeController(ScriptedUI())
        c.copy([a, b], cut: true)
        #expect(c.cutURLs == [a, b])

        let pasted = try await c.paste(into: try s.folder("dst"))
        #expect(pasted.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(s.listing("src").isEmpty && s.listing("dst") == ["a.txt", "b.txt"])
        #expect(c.cutURLs.isEmpty && c.clipboardURLs.isEmpty)
        #expect(c.pasteTitle == "Paste")
    }

    @Test func copyThenPasteCanBeRepeated() async throws {
        let s = try Scratch()
        let f = try s.file("src/f.txt", "f")
        let c = makeController(ScriptedUI())
        c.copy([f], cut: false)
        #expect(c.cutURLs.isEmpty)
        _ = try await c.paste(into: try s.folder("one"))
        _ = try await c.paste(into: try s.folder("two"))
        #expect(s.read("one/f.txt") == "f" && s.read("two/f.txt") == "f" && s.read("src/f.txt") == "f")
        #expect(c.clipboardURLs == [f])
    }

    @Test func failedCancelledAndPartlySkippedMovesKeepOnlyUnmovedCuts() async throws {
        let s = try Scratch()
        let first = try s.file("src/first.txt", "first"), second = try s.file("src/second.txt", "second")
        try s.file("dst/first.txt", "existing first"); try s.file("dst/second.txt", "existing second")
        let ui = ScriptedUI(conflicts: [.init(.cancel)])
        let c = makeController(ui)
        c.copy([first, second], cut: true)
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.clipboardURLs == [first, second] && c.cutURLs == [first, second])
        ui.conflictAnswers = [.init(.rename("kept first.txt")), .init(.skip)]
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.clipboardURLs == [second] && c.cutURLs == [second])
        #expect(s.read("dst/first.txt") == "existing first" && s.read("dst/kept first.txt") == "first")
        #expect(s.read("src/second.txt") == "second")
        ui.conflictAnswers = [.init(.overwrite)]
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.clipboardURLs.isEmpty && c.cutURLs.isEmpty && s.read("dst/second.txt") == "second")
        let missing = s.path("src/missing.txt")
        c.copy([missing], cut: true)
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.clipboardURLs == [missing] && c.cutURLs == [missing])
    }

    @Test func aNewClipboardDuringAnInFlightMoveIsNeverCleared() async throws {
        let s = try Scratch(), first = try s.file("src/a.txt", "new"), next = try s.file("next.txt", "next")
        try s.file("dst/a.txt", "old")
        let ui = ScriptedUI(), c = makeController(ui)
        ui.asyncConflict = { _, _, done in
            c.copy([next], cut: true); done(.init(.overwrite))
        }
        c.copy([first], cut: true)
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.clipboardURLs == [next] && c.cutURLs == [next])
        #expect(s.read("dst/a.txt") == "new" && s.read("next.txt") == "next")
        ui.asyncConflict = nil
    }

    @Test func aMergedMoveWithSkippedChildrenStaysCut() async throws {
        let s = try Scratch()
        let folder = try s.folder("src/folder")
        try s.file("src/folder/a.txt", "keep"); try s.file("dst/folder/a.txt", "existing")
        let c = makeController(ScriptedUI(conflicts: [.init(.writeInto), .init(.skip)]))
        c.copy([folder], cut: true)
        _ = try await c.paste(into: s.path("dst"))
        #expect(c.cutURLs == [folder] && c.clipboardURLs == [folder])
        #expect(s.read("src/folder/a.txt") == "keep" && s.read("dst/folder/a.txt") == "existing")
    }

    @Test func aCutReplacedOnTheClipboardBySomeoneElseIsCopiedInstead() async throws {
        let s = try Scratch()
        let mine = try s.file("src/mine.txt"), theirs = try s.file("src/theirs.txt")
        let c = makeController(ScriptedUI())
        c.copy([mine], cut: true)
        c.clipboard.write([theirs])  // another app copies something
        _ = try await c.paste(into: try s.folder("dst"))
        #expect(s.listing("src") == ["mine.txt", "theirs.txt"] && s.listing("dst") == ["theirs.txt"])
    }

    @Test func cuttingNothingKeepsThePreviousCut() throws {
        let s = try Scratch()
        let x = try s.file("x")
        let c = makeController(ScriptedUI())
        c.copy([x], cut: true)
        c.copy([], cut: true)
        #expect(c.cutURLs == [x] && c.clipboardURLs == [x])
    }

    @Test func pasteTitleDescribesWhatIsOnTheClipboard() throws {
        let s = try Scratch()
        let f1 = try s.file("1.txt"), f2 = try s.file("2.txt"), d1 = try s.folder("d1"), d2 = try s.folder("d2")
        let c = makeController(ScriptedUI())
        let cases: [([URL], String)] = [
            ([], "Paste"), ([f1], "Paste One File"), ([d1], "Paste One Folder"), ([f1, f2], "Paste 2 Files"),
            ([d1, d2], "Paste 2 Folders"), ([f1, d1], "Paste 2 Items"),
        ]
        for (urls, title) in cases {
            c.clipboard.write(urls)
            #expect(c.pasteTitle == title)
        }
    }

    @Test func webLinksAreNotFilesToPaste() throws {
        let c = makeController(ScriptedUI())
        let remote = URL(string: "sftp://me@host/home/me/file.txt")!
        c.clipboard.write([URL(string: "https://example.com/page")!, remote, URL(fileURLWithPath: "/tmp/x")])
        #expect(c.clipboardURLs == [remote, URL(fileURLWithPath: "/tmp/x")])
    }
}
