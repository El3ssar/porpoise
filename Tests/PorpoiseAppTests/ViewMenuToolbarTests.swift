import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// P11 W-268: the View menu in Finder's order, the bar items in it, and the Mac key set's toolbar ending with Share and
/// Action ⋯ (Dolphin's keeps its menu).
@MainActor @Suite(.serialized, .isolatedSettings) struct ViewMenuToolbarTests {
    private typealias W = MainWindowController
    init() { _ = NSApplication.shared }

    private func viewMenu(_ keySet: ShortcutKeySet) throws -> NSMenu {
        Settings.shared.shortcutKeySet = keySet
        let bar = AppDelegate.shared.buildMainMenu()
        NSApp.mainMenu = bar
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        return try #require(bar.items.first { $0.title == "View" }?.submenu)
    }

    /// A browser on a scratch folder with the key set's menu bar, its list focused.
    private func browser(_ s: Scratch, _ keySet: ShortcutKeySet) async throws -> (W, NSWindow) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        _ = try viewMenu(keySet)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        let window = try #require(wc.window)
        window.orderFront(nil)
        try #require(await eventually { !wc.view.model.isLoading })
        #expect(window.makeFirstResponder(wc.view.list))
        return (wc, window)
    }

    /// A key press through AppKit's own dispatch, as the system delivers it (`NSApp.sendEvent`).
    private func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
    }

    /// A click on `view` through the window, as the system delivers it: mouse down and up at its centre.
    private func click(_ view: NSView, in window: NSWindow) throws {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // What a real click there reaches: the button itself, not something over it.
        #expect(window.contentView?.superview?.hitTest(point) === view)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    @Test(arguments: ShortcutKeySet.allCases) func viewMenuStartsWithTheModesAsFinderDoes(_ keySet: ShortcutKeySet) throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let view = try viewMenu(keySet)
        let modes = Array(view.items.prefix(4))
        #expect(modes.allSatisfy { $0.action == #selector(W.setViewMode(_:)) && $0.keyEquivalentModifierMask == .command })
        #expect(modes.map(\.keyEquivalent) == ["1", "2", "3", "4"])
        let order = keySet == .dolphin ? ["Icons", "Compact", "Details", "Columns"] : ["Icons", "Details", "Compact", "Columns"]
        #expect(modes.map(\.title) == order.map { "as " + $0 })
        #expect(view.items[4].isSeparatorItem && view.items[5].title == "Sort By")
        // No View Mode submenu left in the menu bar; the bar items are there.
        #expect(!view.items.contains { $0.title == "View Mode" })
        #expect(view.items.contains { $0.action == #selector(W.toggleStatusBar(_:)) && $0.keyEquivalent == "/" })
        #expect(view.items.contains { $0.action == #selector(W.toggleTabBar(_:)) })
    }

    /// ⌘/ hides the status bar and shows it again in the style it had; the menu item says which it will do.
    @Test func commandSlashHidesAndShowsTheStatusBar() async throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        Settings.shared.statusBarMode = .small
        let item = try #require(
            NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.first { $0.action == #selector(W.toggleStatusBar(_:)) })
        // AppKit's dispatch matches ⌘/ to this item; its nil-targeted action then goes to the key window. The test host
        // can't have one without activating the app (it would take focus from the user), so the item is aimed at this
        // window as the key window would be. Without this the key still reaches the item, but its action goes nowhere.
        item.target = wc
        _ = wc.validateMenuItem(item)
        #expect(item.title == "Hide Status Bar")
        try press(44, "/", .command, in: window)
        #expect(await eventually { Settings.shared.statusBarMode == .disabled })
        _ = wc.validateMenuItem(item)
        #expect(item.title == "Show Status Bar")
        try press(44, "/", .command, in: window)
        #expect(await eventually { Settings.shared.statusBarMode == .small })
        Settings.shared.statusBarMode = .fullWidth
    }

    @Test func tabBarItemFollowsTheSetting() async throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let s = try Scratch()
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        let item = NSMenuItem(title: "Always Show Tab Bar", action: #selector(W.toggleTabBar(_:)), keyEquivalent: "")
        Settings.shared.alwaysShowTabBar = false
        wc.toggleTabBar(item)
        _ = wc.validateMenuItem(item)
        #expect(Settings.shared.alwaysShowTabBar && item.state == .on && wc.tabBarVisible)
        wc.toggleTabBar(item)
        #expect(!Settings.shared.alwaysShowTabBar)
    }

    /// The Mac key set's toolbar ends with Share and Action ⋯; Dolphin's with its menu. Action opens the selection's
    /// context menu (the folder's without one).
    @Test func macToolbarHasShareAndActionDolphinsHasItsMenu() async throws {
        let previous = NSApp.mainMenu, popUp = W.popUpActionMenu
        defer {
            NSApp.mainMenu = previous
            W.popUpActionMenu = popUp
            MenuCommandRegistry.shared.refresh(fillDynamic: false)
        }
        #expect(ToolbarCommand.defaults(for: .mac).suffix(2) == [.share, .action])
        #expect(ToolbarCommand.defaults(for: .dolphin).last == .menu)
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        #expect(Settings.shared.toolbarCommands == ToolbarCommand.defaults(for: .mac))
        wc.toolbar.layoutSubtreeIfNeeded()
        let share = try #require(wc.toolbar.buttonForTesting(.share)), action = try #require(wc.toolbar.buttonForTesting(.action))
        let menu = try #require(wc.toolbar.buttonForTesting(.menu))
        #expect(share.superview != nil && !share.isHidden && action.superview != nil && !action.isHidden)
        #expect(menu.superview == nil || menu.isHidden || menu.window == nil)
        #expect(share.frame.maxX <= action.frame.minX)
        var shown: [String] = []
        W.popUpActionMenu = { m, button in
            #expect(button === action)
            shown = m.items.filter { !$0.isSeparatorItem }.map(\.title)
        }
        try click(action, in: window)
        #expect(await eventually { shown.first == "New Folder…" })
        let file = try #require(wc.view.model.rows.first { $0.item.name == "a.txt" }?.item.url)
        wc.view.list.select(file)
        shown = []
        try click(action, in: window)
        #expect(await eventually { !shown.isEmpty })
        #expect(shown.contains("Get Info") && shown.contains("Move to Trash") && !shown.contains("New Folder…"))
        // Dolphin's keys: the menu comes back in place of Share and Action.
        Settings.shared.shortcutKeySet = .dolphin
        wc.toolbar.needsLayout = true
        wc.toolbar.layoutSubtreeIfNeeded()
        #expect(menu.superview != nil && !menu.isHidden && action.superview == nil)
        Settings.shared.shortcutKeySet = .mac
    }
}
