import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct PresetMenuTests {
    private typealias W = MainWindowController
    init() { _ = NSApplication.shared }

    private func install(_ preset: ShortcutKeySet) -> NSMenu {
        Settings.shared.shortcutKeySet = preset
        let menu = AppDelegate.shared.buildMainMenu()
        NSApp.mainMenu = menu
        MenuCommandRegistry.shared.start()
        return menu
    }
    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    private func id(_ action: Selector) -> String { NSStringFromSelector(action) + "#0#" }
    private func binding(_ item: NSMenuItem) -> KeyboardShortcut {
        KeyboardShortcut(key: item.keyEquivalent, modifiers: ShortcutModifiers(item.keyEquivalentModifierMask))
    }
    private func verifyEveryMenuBinding(_ menu: NSMenu) {
        let registry = MenuCommandRegistry.shared
        let commands = Dictionary(uniqueKeysWithValues: registry.commands.map { ($0.id, $0) })
        var checked = 0
        for item in items(menu) where item.action != nil && item.submenu == nil && !MenuCommandRegistry.isAppKits(item) {
            let identifier = MenuCommandRegistry.id(item)
            guard let command = commands[identifier], let expected = registry.dispatchBindings[identifier],
                let index = ([command.item] + command.aliases).firstIndex(where: { $0 === item }), expected.indices.contains(index)
            else { Issue.record("A menu command has no dispatch binding: \(identifier)"); continue }
            #expect(binding(item).normalized == expected[index].normalized)
            #expect(binding(item).display == expected[index].display)
            checked += 1
        }
        #expect(checked > 75)
    }

    @Test func wholeMenuMatchesDispatchForBothPresetsOverridesAndClearedAliases() throws {
        let old = NSApp.mainMenu
        defer { NSApp.mainMenu = old; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        for preset in ShortcutKeySet.allCases {
            Settings.shared.keyboardShortcuts = ShortcutPreferences()
            var menu = install(preset)
            verifyEveryMenuBinding(menu)
            let registry = MenuCommandRegistry.shared
            let open = registry.shortcut(for: #selector(W.openSelected(_:)))
            let rename = registry.shortcut(for: #selector(W.renameItem(_:)))
            let trash = registry.shortcut(for: #selector(W.moveToTrash(_:)))
            let delete = registry.shortcut(for: #selector(W.deleteItem(_:)))
            if preset == .dolphin {
                #expect(open == KeyboardShortcut(key: "\r"))
                #expect(rename == KeyboardShortcut(key: KeyEquivalent.f(2)))
                #expect(trash == KeyboardShortcut(key: KeyEquivalent.forwardDelete))
                #expect(delete == KeyboardShortcut(key: KeyEquivalent.forwardDelete, modifiers: .shift))
            } else {
                #expect(rename == KeyboardShortcut(key: "\r"))
                #expect(trash == KeyboardShortcut(key: KeyEquivalent.backspace, modifiers: .command))
                #expect(delete == KeyboardShortcut(key: KeyEquivalent.backspace, modifiers: [.command, .option]))
                #expect(
                    registry.dispatchBindings[id(#selector(W.openSelected(_:)))]?.contains(
                        KeyboardShortcut(key: KeyEquivalent.down, modifiers: .command)) == true)
            }
            var preferences = ShortcutPreferences()
            let custom = KeyboardShortcut(key: "8", modifiers: [.command, .control, .option])
            preferences.overrides[id(#selector(W.openSelected(_:)))] = custom
            Settings.shared.keyboardShortcuts = preferences
            menu = try #require(NSApp.mainMenu)
            verifyEveryMenuBinding(menu)
            #expect(registry.shortcut(for: #selector(W.openSelected(_:))) == custom)
            let openItems = registry.commands.first { $0.id == id(#selector(W.openSelected(_:))) }
            #expect(openItems?.aliases.allSatisfy { $0.keyEquivalent.isEmpty } == true)
            preferences.overrides[id(#selector(W.openSelected(_:)))] = KeyboardShortcut()
            Settings.shared.keyboardShortcuts = preferences
            menu = try #require(NSApp.mainMenu)
            verifyEveryMenuBinding(menu)
            #expect(registry.shortcut(for: #selector(W.openSelected(_:))).isEmpty)
            #expect(!registry.fallbackAllowed(#selector(W.openSelected(_:))))
            // A newly conflicting import must restore defaults, rather than leaving an earlier override displayed.
            preferences.overrides[id(#selector(W.openSelected(_:)))] = custom
            Settings.shared.keyboardShortcuts = preferences
            preferences.overrides[id(#selector(W.goUp(_:)))] = custom
            Settings.shared.keyboardShortcuts = preferences
            verifyEveryMenuBinding(try #require(NSApp.mainMenu))
            #expect(registry.shortcut(for: #selector(W.openSelected(_:))) == open)
            #expect(registry.fallbackAllowed(#selector(W.openSelected(_:))))
        }
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private func cell(_ table: NSTableView, _ column: String, _ row: Int) -> NSView? {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == column }) else { return nil }
        return table.delegate?.tableView?(table, viewFor: column, row: row) ?? nil
    }
    private func displayed(_ table: NSTableView, path: String, pathColumn: String, keyColumn: String) -> String? {
        for row in 0..<table.numberOfRows {
            guard let view = cell(table, pathColumn, row) else { continue }
            let labels = descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
            if labels.contains(where: { $0 == path || $0 == "Unavailable · " + path }) {
                return (cell(table, keyColumn, row) as? NSTextField)?.stringValue
            }
        }
        return nil
    }

    @Test func contextToolbarPaletteAndSettingsRefreshLiveFromTheSameBindings() async throws {
        let old = NSApp.mainMenu
        defer { NSApp.mainMenu = old; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        _ = install(.mac)
        let scratch = try Scratch(), file = try scratch.file("one.txt", "original")
        let owner = W(urls: [scratch.url])
        defer { owner.window?.close() }
        owner.showWindow(nil)
        try #require(await eventually { !owner.view.model.isLoading })
        owner.view.model.selection = [file]
        let editor = ShortcutEditorView(frame: .zero)
        let editorTable = try #require(descendants(editor).compactMap { $0 as? NSTableView }.first)
        let palette = CommandPalette(owner: owner)
        defer { palette.window?.close() }
        let root = try #require(palette.window?.contentView)
        let paletteTable = try #require(descendants(root).compactMap { $0 as? NSTableView }.first)
        let query = try #require(descendants(root).compactMap { $0 as? NSSearchField }.first)
        query.stringValue = "File Open"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: query))
        Settings.shared.shortcutKeySet = .dolphin
        try #require(
            await eventually {
                displayed(editorTable, path: "File › Open", pathColumn: "action", keyColumn: "current") == "↩"
                    && displayed(paletteTable, path: "File › Open", pathColumn: "command", keyColumn: "shortcut") == "↩"
            })
        let item = FileItem(url: file, name: "one.txt", isDirectory: false)
        var context = owner.contextMenu(for: item, in: owner.view)
        let rename = try #require(items(context).first { $0.action == #selector(W.renameItem(_:)) })
        #expect(binding(rename).display == "F2")
        let trash = try #require(items(context).first { $0.action == #selector(W.moveToTrash(_:)) })
        #expect(binding(trash).display == "⌦")
        var preferences = ShortcutPreferences()
        let custom = KeyboardShortcut(key: "8", modifiers: [.command, .control, .option])
        let up = KeyboardShortcut(key: "9", modifiers: [.command, .control, .option])
        preferences.overrides[id(#selector(W.openSelected(_:)))] = custom
        preferences.overrides[id(#selector(W.goUp(_:)))] = up
        preferences.overrides[id(#selector(W.renameItem(_:)))] = KeyboardShortcut()
        Settings.shared.keyboardShortcuts = preferences
        try #require(
            await eventually {
                displayed(editorTable, path: "File › Open", pathColumn: "action", keyColumn: "current") == custom.display
                    && displayed(paletteTable, path: "File › Open", pathColumn: "command", keyColumn: "shortcut") == custom.display
                    && owner.toolbar.up.toolTip == "Up (\(up.display))"
            })
        context = owner.contextMenu(for: item, in: owner.view)
        #expect(items(context).first { $0.action == #selector(W.renameItem(_:)) }?.keyEquivalent.isEmpty == true)
        Settings.shared.shortcutKeySet = .mac
        try #require(await eventually { owner.toolbar.up.toolTip == "Up (\(up.display))" })
        context = owner.contextMenu(for: item, in: owner.view)
        #expect(items(context).first { $0.action == #selector(W.moveToTrash(_:)) }.map(binding)?.display == "⌘⌫")
        #expect(displayed(editorTable, path: "File › Open", pathColumn: "action", keyColumn: "current") == custom.display)
    }

    @Test func clearingAnActionNeverRevivesTheOldReturnOpenFallback() async throws {
        let old = NSApp.mainMenu
        defer { NSApp.mainMenu = old; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let scratch = try Scratch(), folder = try scratch.folder("child")
        let owner = W(urls: [scratch.url])
        defer { owner.window?.close() }
        owner.showWindow(nil)
        try #require(await eventually { !owner.view.model.isLoading })
        owner.view.model.selection = [folder]; owner.view.model.currentURL = folder
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        for preset in ShortcutKeySet.allCases {
            _ = install(preset)
            var preferences = ShortcutPreferences()
            preferences.overrides[id(preset == .mac ? #selector(W.renameItem(_:)) : #selector(W.openSelected(_:)))] = KeyboardShortcut()
            Settings.shared.keyboardShortcuts = preferences
            let previous = owner.view.url
            owner.view.list.keyDown(with: key)
            #expect(owner.view.url == previous && !owner.view.list.isRenaming)
        }
    }
}
