import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

@Suite(.isolatedSettings) struct CommandCustomizationTests {
    @Test func fuzzyRankingPrefersExactThenPrefixThenSubstringThenSubsequence() throws {
        let candidates = ["Open", "Open Folder", "Reopen", "Options enabled"].enumerated().map {
            CommandCandidate(id: String($0.offset), title: $0.element)
        }
        let matches = CommandSearch.rank("open", candidates: candidates)
        #expect(matches.map { $0.candidate.title } == ["Open", "Open Folder", "Reopen", "Options enabled"])
        #expect(CommandSearch.score("xyz", in: "Something else") == nil)
        #expect(CommandSearch.score("xy", in: "a y") == nil)
        #expect(CommandSearch.score("longer", in: "a") == nil)
    }
    @Test func boundariesDiacriticsTokensAndSecondaryFields() throws {
        #expect(CommandSearch.score("cafe", in: "Café") == 100000)
        #expect(try #require(CommandSearch.score("ot", in: "Open Terminal")) > #require(CommandSearch.score("ot", in: "Something")))
        let candidates = [
            CommandCandidate(id: "1", title: "Pictures", subtitle: "Place / bookmark · /Users/name/Pictures"),
            CommandCandidate(id: "2", title: "New Tab", subtitle: "File › New Tab"),
        ]
        #expect(CommandSearch.rank("bookmark pictures", candidates: candidates).map { $0.candidate.id } == ["1"])
        #expect(CommandSearch.rank("   ", candidates: candidates).count == 2)
        #expect(CommandSearch.rank("", candidates: candidates, limit: 1).count == 1)
        #expect(CommandSearch.rank("", candidates: candidates, limit: -1).isEmpty)
    }
    @Test func tiesAreStableAndDisabledActionsRemainSearchable() {
        let candidates = [
            CommandCandidate(id: "b", title: "Copy", enabled: false), CommandCandidate(id: "c", title: "Copy"),
            CommandCandidate(id: "a", title: "Copy"),
        ]
        #expect(CommandSearch.rank("copy", candidates: candidates).map { $0.candidate.id } == ["a", "c", "b"])
        #expect(CommandSearch.rank("missing", candidates: candidates).isEmpty)
    }
    @Test func normalizedChordsAndDisplay() throws {
        let commandP = KeyboardShortcut(key: "p", modifiers: .command)
        #expect(commandP.display == "⌘P")
        #expect(KeyboardShortcut(key: "P", modifiers: .command).normalized == KeyboardShortcut(key: "p", modifiers: [.command, .shift]))
        #expect(KeyboardShortcut(key: "+", modifiers: .command).normalized == KeyboardShortcut(key: "=", modifiers: [.command, .shift]))
        #expect(KeyboardShortcut(key: "\u{f705}").display == "F2")
        #expect(KeyboardShortcut(key: "\u{f728}", modifiers: .shift).display == "⇧⌦")
        #expect(KeyboardShortcut().display == "—")
        #expect(throws: (any Error).self) { try KeyboardShortcut(key: "two keys").validate() }
        #expect(throws: (any Error).self) { try KeyboardShortcut(key: "\0").validate() }
        #expect(throws: (any Error).self) { try KeyboardShortcut(key: "k", modifiers: ShortcutModifiers(rawValue: 16)).validate() }
    }
    private var actions: [ShortcutAction] {
        [
            ShortcutAction(
                id: "open", title: "File › Open",
                defaults: [KeyboardShortcut(key: "o", modifiers: .command), KeyboardShortcut(key: "\u{f701}", modifiers: .command)]),
            ShortcutAction(id: "new", title: "File › New", defaults: [KeyboardShortcut(key: "n", modifiers: .command)]),
            ShortcutAction(id: "zoom", title: "View › Zoom", defaults: [KeyboardShortcut(key: "+", modifiers: .command)]),
        ]
    }
    @Test func conflictsIncludeHiddenAliasesAndImpliedShift() throws {
        var preferences = ShortcutPreferences()
        #expect(preferences.conflicts(actions: actions).isEmpty)
        preferences.overrides["new"] = KeyboardShortcut(key: "\u{f701}", modifiers: .command)
        #expect(preferences.conflicts(actions: actions).count == 1)
        preferences.overrides["open"] = KeyboardShortcut(key: "r", modifiers: .command)
        #expect(preferences.conflicts(actions: actions).isEmpty)  // override replaces hidden aliases too
        preferences.overrides["new"] = KeyboardShortcut(key: "=", modifiers: [.command, .shift])
        #expect(preferences.conflicts(actions: actions).count == 1)
        preferences.overrides["zoom"] = KeyboardShortcut()
        #expect(preferences.conflicts(actions: actions).isEmpty)
    }
    @Test func importsValidateAtomicallyAndRoundTrip() throws {
        var preferences = ShortcutPreferences(); preferences.overrides["open"] = KeyboardShortcut(key: "r", modifiers: [.command, .option])
        #expect(try ShortcutPreferences.decode(preferences.encoded()) == preferences)
        try Settings.shared.importKeyboardShortcuts(preferences.encoded(), actions: actions)
        #expect(Settings.shared.keyboardShortcuts == preferences)
        var conflict = preferences; conflict.overrides["new"] = KeyboardShortcut(key: "r", modifiers: [.command, .option])
        #expect(throws: (any Error).self) { try Settings.shared.importKeyboardShortcuts(conflict.encoded(), actions: actions) }
        #expect(Settings.shared.keyboardShortcuts == preferences)
        var invalid = preferences; invalid.version = 99
        #expect(throws: (any Error).self) { try ShortcutPreferences.decode(JSONEncoder().encode(invalid)) }
        #expect(throws: (any Error).self) { try ShortcutPreferences.decode(Data("bad json".utf8)) }
        Settings.shared.resetAll(); #expect(Settings.shared.keyboardShortcuts.overrides.isEmpty)
    }
    @Test func toolbarOrderPersistsAndInvalidLayoutsAreRejected() throws {
        let layout: [ToolbarCommand] = [.reload, .location, .newTab, .commandPalette]
        Settings.shared.toolbarCommands = layout
        #expect(Settings.shared.toolbarCommands == layout)
        #expect(throws: (any Error).self) { try ToolbarCommand.validate([.back, .forward]) }
        #expect(throws: (any Error).self) { try ToolbarCommand.validate([.location, .back, .back]) }
        Settings.shared.toolbarCommands = [.back]
        #expect(Settings.shared.toolbarCommands == layout)
        Settings.shared.resetAll(); #expect(Settings.shared.toolbarCommands == ToolbarCommand.defaults)
    }
}
