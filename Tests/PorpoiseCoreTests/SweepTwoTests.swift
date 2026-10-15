import Foundation
import Testing

@testable import PorpoiseCore

/// Regressions found by the second codebase sweep (Core).
struct SweepTwoCoreTests {
    @Test func renameKeepsTheStemWhenAMarkFollowsTheDot() throws {
        let entry = BatchRenameEntry(url: URL(fileURLWithPath: "/x/a.\u{301}x"))
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "")) == "a.\u{301}x")
    }

    @Test func aTypedDotInANewExtensionIsNotDoubled() throws {
        let entry = BatchRenameEntry(url: URL(fileURLWithPath: "/x/photo.png"))
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "", extensionMode: .change(".jpg"))) == "photo.jpg")
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "", extensionMode: .change("jpg"))) == "photo.jpg")
    }

    @Test func appearanceFromAnOlderVersionKeepsWhatItHas() throws {
        // A field this version doesn't know is ignored; fields it lacks get their defaults; the rest is kept.
        let json = #"{"version":1,"themeName":"Nord","iconsSize":96,"futureField":true}"#
        let value = try JSONDecoder().decode(AppearancePreferences.self, from: Data(json.utf8))
        #expect(value.themeName == "Nord" && value.iconsSize == 96 && value.scrollback == AppearancePreferences().scrollback)
        try value.validate()
        // Round trip.
        let back = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(value))
        #expect(back == value)
    }

    @Test func folderVariantsArePlainNames() throws {
        var p = AppearancePreferences()
        p.folderVariant = "blue-dark"
        try p.validate()
        for bad in ["../x", "/tmp/x", "", "a/b"] {
            p.folderVariant = bad
            #expect(throws: AppearanceError.self) { try p.validate() }
        }
    }

    @Test func defaultsThatShareAKeyDontBlockTheUsersBindings() {
        // The system's Services menu brings ⌘⇧L, as Go › Library has: not the user's clash.
        let actions = [
            ShortcutAction(id: "goLibrary", title: "Library", defaults: [KeyboardShortcut(key: "l", modifiers: [.command, .shift])]),
            ShortcutAction(id: "service", title: "Search With Google", defaults: [KeyboardShortcut(key: "L", modifiers: [.command])]),
            ShortcutAction(id: "palette", title: "Palette", defaults: [KeyboardShortcut(key: "p", modifiers: [.command, .shift])]),
        ]
        var prefs = ShortcutPreferences()
        #expect(prefs.conflicts(actions: actions).isEmpty)
        // A binding of the user's own onto a taken key is still a clash.
        prefs.overrides["palette"] = KeyboardShortcut(key: "l", modifiers: [.command, .shift])
        #expect(
            prefs.conflicts(actions: actions) == [
                ShortcutConflict(first: "goLibrary", second: "palette", shortcut: KeyboardShortcut(key: "l", modifiers: [.command, .shift]))
            ])
    }

    @Test func shortcutsNeedAModifierUnlessFunctionOrNavigationKeys() throws {
        #expect(throws: ShortcutError.self) { try KeyboardShortcut(key: "p").validate() }
        #expect(throws: ShortcutError.self) { try KeyboardShortcut(key: "\r", modifiers: .shift).validate() }
        try KeyboardShortcut().validate()
        try KeyboardShortcut(key: "p", modifiers: .option).validate()
        try KeyboardShortcut(key: "\u{f705}").validate()  // F2
        try KeyboardShortcut(key: "\u{f700}").validate()  // ↑
    }

    @Test func handWrittenShortcutFilesImport() throws {
        let a = try ShortcutPreferences.decode(Data(#"{"overrides":{}}"#.utf8))
        #expect(a.overrides.isEmpty && a.version == 1)
        let b = try ShortcutPreferences.decode(Data(#"{"version":1,"overrides":{"x":{"key":"\uF705"}}}"#.utf8))
        #expect(b.overrides["x"] == KeyboardShortcut(key: "\u{f705}"))
    }

    @Test func initialsRankAboveAMatchInsideAWord() {
        func first(_ q: String, _ titles: [String]) -> String? {
            CommandSearch.rank(q, candidates: titles.enumerated().map { CommandCandidate(id: "\($0.offset)", title: $0.element) }).first?.candidate
                .title
        }
        #expect(first("nf", ["Information", "New Folder"]) == "New Folder")
        #expect(first("et", ["Delete", "Empty Trash"]) == "Empty Trash")
        #expect(first("trash", ["Moves to Trashcan", "Empty Trash"]) == "Empty Trash")
        #expect(first("open", ["Reopen", "Options enabled"]) == "Reopen")
    }

    func duplicate(_ path: String, inode: UInt64, date: Double = 0, clone: UInt64? = nil) -> DuplicateFile {
        DuplicateFile(
            entry: DiskEntry(
                url: URL(fileURLWithPath: path), identity: DiskIdentity(device: 1, inode: inode), directory: false, size: 10, allocated: 4096,
                modified: Date(timeIntervalSince1970: date)), cloneID: clone)
    }

    @Test func keepInFolderLeavesGroupsWithNoCopyThere() {
        let elsewhere = DuplicateGroup(digest: "a", files: [duplicate("/a/x", inode: 1), duplicate("/b/x", inode: 2)])
        let here = DuplicateGroup(digest: "b", files: [duplicate("/keep/y", inode: 3), duplicate("/c/y", inode: 4)])
        let keep = URL(fileURLWithPath: "/keep")
        #expect(DuplicateKeepRule.inFolder.keeper(in: elsewhere, preferredFolder: keep) == nil)
        #expect(DuplicateKeepRule.inFolder.marked(in: [elsewhere, here], preferredFolder: keep) == [URL(fileURLWithPath: "/c/y")])
    }

    @Test func markingThousandsOfCopiesIsLinear() {
        let files = (0..<20_000).map { duplicate("/d/\($0)/LICENSE", inode: UInt64($0), date: Double($0), clone: $0 % 2 == 0 ? 7 : nil) }
        let group = DuplicateGroup(digest: "x", files: files)
        let start = Date()
        let marked = DuplicateKeepRule.newest.marked(in: [group])
        let clones = group.clones
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(marked.count == 19_999 && !marked.contains(URL(fileURLWithPath: "/d/19999/LICENSE")))
        #expect(clones.filter { $0 }.count == 10_000)
        let few = DuplicateGroup(digest: "y", files: Array(files.prefix(5)))
        #expect(few.clones == few.files.map { few.isClone($0) })
    }

    @Test func manifestMessagesWithoutALineSayNoLine() {
        #expect(ChecksumManifest.Invalid(line: 0, reason: "path escapes manifest folder").errorDescription == "Path escapes manifest folder")
        #expect(ChecksumManifest.Invalid(line: 3, reason: "bad").errorDescription == "Manifest line 3: bad")
    }
}
