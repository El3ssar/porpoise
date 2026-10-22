import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Settings › Shortcuts › Key set: Finder's keys by default, Dolphin's (the map before 0.9.2) as a one-click choice.
@MainActor struct KeySetTests {
    private typealias W = MainWindowController

    private func menu(_ keySet: ShortcutKeySet) -> NSMenu {
        _ = NSApplication.shared
        Settings.shared.shortcutKeySet = keySet
        return AppDelegate.shared.buildMainMenu()
    }
    private func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    /// (id, key, modifiers) of every item with a key, as the registry and AppKit see them.
    private func bindings(_ m: NSMenu) -> [String] {
        items(m).filter { $0.action != nil && !$0.keyEquivalent.isEmpty && !MenuCommandRegistry.isAppKits($0) }.map {
            "\(MenuCommandRegistry.id($0)) \($0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }) \($0.keyEquivalentModifierMask.rawValue)"
        }.sorted()
    }
    private func item(_ m: NSMenu, _ action: Selector, tag: Int = 0) -> NSMenuItem? {
        items(m).first { $0.action == action && $0.tag == tag && !$0.isHidden }
    }
    private func shortcut(_ item: NSMenuItem?) -> String {
        guard let item else { return "missing" }
        return KeyboardShortcut(key: item.keyEquivalent, modifiers: ShortcutModifiers(item.keyEquivalentModifierMask)).display
    }

    @Test(.isolatedSettings) func newInstallsGetTheMacKeys() {
        #expect(Settings.shared.shortcutKeySet == .mac)
        let m = menu(.mac)
        #expect(shortcut(item(m, #selector(NSApplication.hide(_:)))) == "⌘H")
        #expect(shortcut(item(m, #selector(NSApplication.hideOtherApplications(_:)))) == "⌥⌘H")
        #expect(shortcut(item(m, #selector(W.toggleHiddenFiles(_:)))) == "⇧⌘.")
        let info = item(m, #selector(W.properties(_:)))
        #expect(info?.title == "Get Info" && shortcut(info) == "⌘I")
        #expect(shortcut(item(m, #selector(W.renameItem(_:)))) == "↩")
        #expect(shortcut(item(m, #selector(W.showFilterBar(_:)))) == "⌥⌘F")
        #expect(shortcut(item(m, #selector(W.moveToTrash(_:)))) == "⌘⌫")
        #expect(shortcut(item(m, #selector(W.deleteItem(_:)))) == "⌥⌘⌫")
        #expect(shortcut(item(m, #selector(W.setViewMode(_:)), tag: ViewMode.allCases.firstIndex(of: .details)!)) == "⌘2")
        #expect(shortcut(item(m, #selector(W.setViewMode(_:)), tag: ViewMode.allCases.firstIndex(of: .compact)!)) == "⌘3")
        #expect(shortcut(item(m, #selector(AppDelegate.showKeyboardShortcuts(_:)))) == "⌘?")
        #expect(item(m, #selector(AppDelegate.showHelp(_:)))?.keyEquivalent == "")
        // F2 still renames (hidden), and no key without ⌘ removes files.
        #expect(items(m).contains { $0.action == #selector(W.renameItem(_:)) && $0.isHidden && $0.keyEquivalent == KeyEquivalent.f(2) })
        #expect(!items(m).contains { $0.keyEquivalent == KeyEquivalent.forwardDelete })
        #expect(!items(m).contains { $0.title == "Customise Toolbar…" } && items(m).contains { $0.title == "Customize Toolbar…" })
        // The view settings dropdown uses the same view-mode keys.
        #expect(W.viewModeItems().map(\.title) == ["Icons", "Details", "Compact", "Columns"])
    }

    /// The Dolphin preset gives back exactly the map earlier versions had (captured from 0.9.1's menu bar), except ⌘?,
    /// which now opens the shortcut sheet instead of the website in both key sets.
    @Test(.isolatedSettings) func dolphinKeysRestoreTheEarlierMap() {
        let before = Self.map091.map { "\($0.0) \($0.1.unicodeScalars.map { String($0.value, radix: 16) }) \($0.2)" }
        var expected = before.filter { !$0.hasPrefix("showHelp:") }
        expected.append("showKeyboardShortcuts:#0# [\"3f\"] 1048576")
        // Column view (0.11) came after: ⌘4 in both key sets.
        expected.append("setViewMode:#3# [\"34\"] 1048576")
        #expect(bindings(menu(.dolphin)) == expected.sorted())
        #expect(W.viewModeItems().map(\.title) == ["Icons", "Compact", "Details", "Columns"])
    }

    /// No two items share a key in either set (what `commandcatalog` would report as a conflict once customized).
    @Test(.isolatedSettings) func neitherKeySetHasDuplicateKeys() {
        for keySet in ShortcutKeySet.allCases {
            var owners: [KeyboardShortcut: String] = [:]
            for i in items(menu(keySet)) where i.action != nil && !i.keyEquivalent.isEmpty && !MenuCommandRegistry.isAppKits(i) {
                let key = KeyboardShortcut(key: i.keyEquivalent, modifiers: ShortcutModifiers(i.keyEquivalentModifierMask)).normalized
                let id = MenuCommandRegistry.id(i)
                #expect(owners[key] == nil || owners[key] == id, "\(keySet): \(key.display) on \(owners[key] ?? "") and \(id)")
                owners[key] = id
            }
            let actions = Dictionary(grouping: items(menu(keySet)).filter { $0.action != nil && !MenuCommandRegistry.isAppKits($0) }) {
                MenuCommandRegistry.id($0)
            }.map { id, items in
                ShortcutAction(
                    id: id, title: id,
                    defaults: items.map { KeyboardShortcut(key: $0.keyEquivalent, modifiers: ShortcutModifiers($0.keyEquivalentModifierMask)) }
                        .filter { !$0.isEmpty })
            }
            #expect(Settings.shared.keyboardShortcuts.conflicts(actions: actions).isEmpty)
        }
    }

    /// Bindings a user made stay theirs in either key set; one that now takes a new default's key is reported as a
    /// conflict (and the registry leaves both as they were) rather than silently winning or losing.
    @Test(.isolatedSettings) func customizedShortcutsSurviveTheNewDefaults() {
        var preferences = ShortcutPreferences()
        preferences.overrides["showFilterBar:#0#"] = KeyboardShortcut(key: "i", modifiers: .command)
        preferences.overrides["renameItem:#0#"] = KeyboardShortcut(key: "r", modifiers: [.command, .shift, .option])
        Settings.shared.keyboardShortcuts = preferences
        for keySet in ShortcutKeySet.allCases {
            Settings.shared.shortcutKeySet = keySet
            #expect(Settings.shared.keyboardShortcuts == preferences)
        }
        let actions = [
            ShortcutAction(id: "showFilterBar:#0#", title: "Filter", defaults: [KeyboardShortcut(key: "f", modifiers: [.command, .option])]),
            ShortcutAction(id: "properties:#0#", title: "Get Info", defaults: [KeyboardShortcut(key: "i", modifiers: .command)]),
        ]
        #expect(preferences.conflicts(actions: actions).map(\.shortcut.display) == ["⌘I"])
        Settings.shared.resetAll()
        #expect(Settings.shared.shortcutKeySet == .mac && Settings.shared.keyboardShortcuts.overrides.isEmpty)
    }

    /// Commands that were only in the context menu are in the menu bar too, so the palette and the keyboard reach them.
    @Test(.isolatedSettings) func contextMenuCommandsAreInTheMenuBar() {
        let m = menu(.mac)
        for action in [
            #selector(W.ctxOpenInNewTab(_:)), #selector(W.ctxOpenInNewWindow(_:)), #selector(W.ctxOpenInSplit(_:)),
            #selector(W.showPackageContents(_:)), #selector(W.extractHere(_:)), #selector(W.restoreFromTrash(_:)),
        ] {
            #expect(item(m, action) != nil, "\(action)")
        }
        let tags = items(m).first { $0.title == "Tags" && $0.submenu != nil }
        #expect(tags?.submenu?.delegate === AppDelegate.shared)
    }

    /// Return renames only from the file list: the guard knows a bare Return binding from ⌥↩ (Dolphin's Get Info).
    @Test(.isolatedSettings) func bareReturnIsRecognized() throws {
        let returnKey = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let rename = try #require(item(menu(.mac), #selector(W.renameItem(_:))))
        #expect(W.isBareReturn(rename, returnKey))
        let info = try #require(item(menu(.dolphin), #selector(W.properties(_:))))
        #expect(shortcut(info) == "⌥↩" && !W.isBareReturn(info, returnKey))
    }

    @Test(.isolatedSettings) func shortcutSheetListsTheMenuBarAndTheFileListKeys() {
        let sections = ShortcutSheet.sections(menu(.mac), keySet: .mac)
        let help = sections.first { $0.title == "Help" }
        #expect(help?.rows == [ShortcutSheet.Row(title: "Keyboard Shortcuts", keys: "⌘?")])
        let file = sections.first { $0.title == "File" }
        #expect(file?.rows.contains(ShortcutSheet.Row(title: "Rename…", keys: "↩  F2")) == true)
        #expect(file?.rows.contains(ShortcutSheet.Row(title: "Open", keys: "⌘O  ⌘↓")) == true)
        #expect(sections.last?.title == "In the File List" && !(sections.last?.rows.contains { $0.title == "Open" } ?? true))
        #expect(ShortcutSheet.listKeys(.dolphin).contains(ShortcutSheet.Row(title: "Open", keys: "↩")))
    }

    /// The README's shortcut table is the Mac key set's menu bar. On a mismatch, the expected table is written next to
    /// the build products so it can be pasted in.
    @Test(.isolatedSettings) func readmeTableMatchesTheMenuBar() throws {
        let table = Self.markdownTable(ShortcutSheet.menuSections(menu(.mac)))
        let readme = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let begin = "<!-- shortcuts:begin -->\n", end = "<!-- shortcuts:end -->"
        let start = try #require(readme.range(of: begin)), stop = try #require(readme.range(of: end))
        let current = String(readme[start.upperBound..<stop.lowerBound])
        if current != table {
            try? table.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-shortcuts.md"), atomically: true, encoding: .utf8)
        }
        #expect(current == table)
    }

    static func markdownTable(_ sections: [ShortcutSheet.Section]) -> String {
        var lines = ["| Menu | Action | Keys |", "|---|---|---|"]
        for section in sections {
            for row in section.rows { lines.append("| \(section.title) | \(row.title) | \(row.keys.replacingOccurrences(of: "  ", with: " or ")) |") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 0.9.1's menu bar: (id, key, modifier flags) of every item with a key.
    static let map091: [(String, String, UInt)] = [
        ("activateTab:#0#", "\u{30}", 524288),
        ("activateTab:#1#", "\u{31}", 524288),
        ("activateTab:#2#", "\u{32}", 524288),
        ("activateTab:#3#", "\u{33}", 524288),
        ("activateTab:#4#", "\u{34}", 524288),
        ("activateTab:#5#", "\u{35}", 524288),
        ("activateTab:#6#", "\u{36}", 524288),
        ("activateTab:#7#", "\u{37}", 524288),
        ("activateTab:#8#", "\u{38}", 524288),
        ("activateTab:#9#", "\u{39}", 524288),
        ("addToShelf:#0#", "\u{73}", 1572864),
        ("adjustViewStyle:#0#", "\u{6a}", 1048576),
        ("closeCurrentTab:#0#", "\u{77}", 1048576),
        ("compareFiles:#0#", "\u{79}", 1572864),
        ("connectToServer:#0#", "\u{6b}", 1048576),
        ("copy:#0#", "\u{63}", 1048576),
        ("copyLocation:#0#", "\u{63}", 1572864),
        ("copyToOtherView:#0#", "\u{f708}", 131072),
        ("createFolder:#0#", "\u{6e}", 1179648),
        ("cut:#0#", "\u{78}", 1048576),
        ("deleteItem:#0#", "\u{8}", 1572864),
        ("deleteItem:#0#", "\u{f728}", 131072),
        ("deselectAll:#0#", "\u{61}", 1572864),
        ("duplicateItem:#0#", "\u{64}", 1048576),
        ("editLocation:#0#", "\u{f709}", 0),
        ("ejectVolume:#0#", "\u{65}", 1048576),
        ("emptyTrash:#0#", "\u{8}", 1179648),
        ("focusLeftPane:#0#", "\u{f702}", 524288),
        ("focusOtherView:#0#", "\u{f706}", 1048576),
        ("focusPlaces:#0#", "\u{70}", 1048576),
        ("focusRightPane:#0#", "\u{f703}", 524288),
        ("focusTerminal:#0#", "\u{f707}", 1179648),
        ("goAirDrop:#0#", "\u{72}", 1179648),
        ("goBack:#0#", "\u{5b}", 1048576),
        ("goBack:#0#", "\u{f702}", 1048576),
        ("goForward:#0#", "\u{5d}", 1048576),
        ("goForward:#0#", "\u{f703}", 1048576),
        ("goHome:#0#", "\u{68}", 1179648),
        ("goHome:#0#", "\u{f729}", 524288),
        ("goNetwork:#0#", "\u{6b}", 1179648),
        ("goToFolder:#0#", "\u{67}", 1179648),
        ("goToTarget:#0#", "\u{66}", 1179648),
        ("goToTarget:#1#", "\u{6f}", 1179648),
        ("goToTarget:#2#", "\u{64}", 1179648),
        ("goToTarget:#3#", "\u{6c}", 1572864),
        ("goToTarget:#4#", "\u{63}", 1179648),
        ("goToTarget:#5#", "\u{61}", 1179648),
        ("goToTarget:#6#", "\u{75}", 1179648),
        ("goToTarget:#7#", "\u{69}", 1179648),
        ("goToTarget:#8#", "\u{6c}", 1179648),
        ("goUp:#0#", "\u{f700}", 1048576),
        ("goUp:#0#", "\u{f700}", 524288),
        ("hide:#0#", "\u{68}", 1703936),
        ("hideOtherApplications:#0#", "\u{68}", 1572864),
        ("invertSelection:#0#", "\u{61}", 1703936),
        ("makeAlias:#0#", "\u{61}", 1310720),
        ("moveToOtherView:#0#", "\u{f709}", 131072),
        ("moveToTrash:#0#", "\u{8}", 1048576),
        ("moveToTrash:#0#", "\u{f728}", 0),
        ("newFolderWithSelection:#0#", "\u{6e}", 1310720),
        ("newTab:#0#", "\u{74}", 1048576),
        ("newWindow:#0#", "\u{6e}", 1048576),
        ("nextTab:#0#", "\u{7d}", 1048576),
        ("nextTab:#0#", "\u{9}", 262144),
        ("nextTab:#0#", "\u{f72d}", 1048576),
        ("openSelected:#0#", "\u{6f}", 1048576),
        ("openSelected:#0#", "\u{f701}", 1048576),
        ("openTerminal:#0#", "\u{f707}", 131072),
        ("openTerminalHere:#0#", "\u{f707}", 655360),
        ("paste:#0#", "\u{76}", 1048576),
        ("performClose:#0#", "\u{77}", 1179648),
        ("performMiniaturize:#0#", "\u{6d}", 1048576),
        ("popOutSplit:#0#", "\u{f706}", 131072),
        ("previousTab:#0#", "\u{7b}", 1048576),
        ("previousTab:#0#", "\u{9}", 393216),
        ("previousTab:#0#", "\u{f72c}", 1048576),
        ("properties:#0#", "\u{d}", 524288),
        ("quickLook:#0#", "\u{79}", 1048576),
        ("redoFileOperation:#0#", "\u{7a}", 1179648),
        ("reloadView:#0#", "\u{f708}", 0),
        ("renameItem:#0#", "\u{f705}", 0),
        ("replaceLocation:#0#", "\u{6c}", 1048576),
        ("revealInFinder:#0#", "\u{72}", 1572864),
        ("saveDocument:#0#", "\u{73}", 1048576),
        ("selectAll:#0#", "\u{61}", 1048576),
        ("setViewMode:#0#", "\u{31}", 1048576),
        ("setViewMode:#1#", "\u{32}", 1048576),
        ("setViewMode:#2#", "\u{33}", 1048576),
        ("showActivity:#0#", "\u{6a}", 1572864),
        ("showCommandPalette:#0#", "\u{69}", 786432),
        ("showCommandPalette:#0#", "\u{70}", 1179648),
        ("showConnections:#0#", "\u{6b}", 1572864),
        ("showFilterBar:#0#", "\u{69}", 1048576),
        ("showHelp:#0#", "\u{3f}", 1048576),
        ("showOriginal:#0#", "\u{72}", 1048576),
        ("showSearch:#0#", "\u{66}", 1048576),
        ("showSettings:#0#", "\u{2c}", 1048576),
        ("splitToTabs:#0#", "\u{f706}", 1179648),
        ("terminate:#0#", "\u{71}", 1048576),
        ("toggleFullScreen:#0#", "\u{66}", 1310720),
        ("toggleHiddenFiles:#0#", "\u{2e}", 1179648),
        ("toggleHiddenFiles:#0#", "\u{68}", 1048576),
        ("toggleLinkedBrowsing:#0#", "\u{6c}", 1310720),
        ("togglePanel:#0#", "\u{f70c}", 0),
        ("togglePanel:#1#", "\u{69}", 1572864),
        ("togglePanel:#1#", "\u{f70d}", 0),
        ("togglePanel:#2#", "\u{f70a}", 0),
        ("togglePanel:#3#", "\u{f707}", 0),
        ("togglePanel:#4#", "\u{f70b}", 0),
        ("togglePreviews:#0#", "\u{f70f}", 0),
        ("toggleSelectionMode:#0#", "\u{20}", 1179648),
        ("toggleSplit:#0#", "\u{f706}", 0),
        ("undoCloseTab:#0#", "\u{74}", 1179648),
        ("undoFileOperation:#0#", "\u{7a}", 1048576),
        ("zoomIn:#0#", "\u{2b}", 1048576),
        ("zoomIn:#0#", "\u{3d}", 1048576),
        ("zoomOut:#0#", "\u{2d}", 1048576),
        ("zoomReset:#0#", "\u{30}", 1048576),
    ]
}
