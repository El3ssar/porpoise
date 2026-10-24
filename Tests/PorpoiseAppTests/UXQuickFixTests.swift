import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// P11 W-263: the empty-space context menu, the Shortcuts list and the sort-direction labels.
@MainActor @Suite(.serialized, .isolatedSettings) struct UXQuickFixTests {
    private typealias W = MainWindowController
    init() { _ = NSApplication.shared }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private func text(_ table: NSTableView, _ column: String, _ row: Int) -> String? {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == column }) else { return nil }
        return (table.delegate?.tableView?(table, viewFor: column, row: row) as? NSTextField)?.stringValue
    }

    /// Finder's first entry on empty space is New Folder; Group By and the view's display style are there too, and
    /// "Sort By" switched off in Settings takes Group By with it.
    @Test func emptySpaceMenuStartsWithNewFolder() async throws {
        let scratch = try Scratch()
        let owner = W(urls: [scratch.url])
        defer { owner.window?.close() }
        owner.showWindow(nil)
        try #require(await eventually { !owner.view.model.isLoading })
        let menu = owner.contextMenu(for: nil, in: owner.view)
        let first = try #require(menu.items.first)
        #expect(first.title == "New Folder…" && first.action == #selector(W.createFolder(_:)))
        #expect(first.keyEquivalent == "n" && first.keyEquivalentModifierMask == [.command, .shift])
        #expect(menu.items.contains { $0.title == "Create New" && $0.submenu != nil })
        #expect(menu.items.contains { $0.title == "Group By" && $0.submenu?.items.isEmpty == false })
        #expect(menu.items.contains { $0.action == #selector(W.adjustViewStyle(_:)) })
        Settings.shared.setContextMenu(.sortBy, false)
        let trimmed = owner.contextMenu(for: nil, in: owner.view)
        #expect(!trimmed.items.contains { $0.title == "Sort By" || $0.title == "Group By" })
    }

    /// The list follows the menu bar's order, and the Default column speaks only where the shortcut differs.
    @Test func shortcutsListIsInMenuOrderAndShowsOnlyChangedDefaults() throws {
        let old = NSApp.mainMenu
        defer {
            NSApp.mainMenu = old
            MenuCommandRegistry.shared.refresh(fillDynamic: false)
        }
        Settings.shared.shortcutKeySet = .mac
        Settings.shared.keyboardShortcuts = ShortcutPreferences()
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        MenuCommandRegistry.shared.start()
        let editor = ShortcutEditorView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let table = try #require(descendants(editor).compactMap { $0 as? NSTableView }.first)
        let paths = (0..<table.numberOfRows).compactMap { text(table, "action", $0) }
        let file = try #require(paths.firstIndex { $0.hasPrefix("File › ") })
        let edit = try #require(paths.firstIndex { $0.hasPrefix("Edit › ") })
        let help = try #require(paths.firstIndex { $0.hasPrefix("Help › ") })
        #expect(file < edit && edit < help)
        let copy = try #require(paths.firstIndex(of: "Edit › Copy"))
        #expect(text(table, "current", copy) == "⌘C" && text(table, "default", copy) == "")
        // Changed: the default shows next to it.
        var preferences = ShortcutPreferences()
        preferences.overrides[NSStringFromSelector(#selector(W.copy(_:))) + "#0#"] = KeyboardShortcut(key: "c", modifiers: [.command, .control])
        Settings.shared.keyboardShortcuts = preferences
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        #expect(text(table, "current", copy) == "⌃⌘C" && text(table, "default", copy) == "⌘C")
        Settings.shared.keyboardShortcuts = ShortcutPreferences()
    }

    /// Text columns read A-Z / Z-A; sizes and dates keep their own words.
    @Test func sortDirectionFollowsTheSortedColumn() {
        for role in [ItemRole.name, .type, .extension_, .path, .owner, .group, .linkDestination] {
            #expect(role.orderLabels == ("A-Z", "Z-A") as (String, String), "\(role)")
        }
        #expect(ItemRole.size.orderLabels.ascending == "Smallest First")
        #expect(ItemRole.modificationTime.orderLabels.descending == "Newest First")
    }

    /// Porpoise never hands off to Finder (operator, P11 #9): no menu-bar or context-menu entry offers it.
    @Test func nothingRevealsInFinder() async throws {
        let old = NSApp.mainMenu
        defer {
            NSApp.mainMenu = old
            MenuCommandRegistry.shared.refresh(fillDynamic: false)
        }
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        for set in ShortcutKeySet.allCases {
            Settings.shared.shortcutKeySet = set
            let bar = AppDelegate.shared.buildMainMenu()
            #expect(!all(bar).contains { $0.title.contains("in Finder") }, "\(set)")
        }
        Settings.shared.shortcutKeySet = .mac
        let scratch = try Scratch(), file = try scratch.file("one.txt", "x")
        let owner = W(urls: [scratch.url])
        defer { owner.window?.close() }
        owner.showWindow(nil)
        try #require(await eventually { !owner.view.model.isLoading })
        let item = FileItem(url: file, name: "one.txt", isDirectory: false)
        for menu in [owner.contextMenu(for: nil, in: owner.view), owner.contextMenu(for: item, in: owner.view)] {
            #expect(!all(menu).contains { $0.title.contains("Finder") })
        }
    }
}
