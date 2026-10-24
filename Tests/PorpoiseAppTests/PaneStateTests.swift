import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// What a pane shows about its own state: one of the search and filter bars at a time, and in a split, which pane
/// the toolbar's commands act on. Keys go through AppKit's own dispatch (`NSApp.sendEvent`).
@MainActor @Suite(.serialized, .isolatedSettings) struct PaneStateTests {
    /// Everything here settles in well under a second; a failure must not hold a shared build lane for minutes.
    static let wait: TimeInterval = 5

    private func browser(_ s: Scratch, _ keySet: ShortcutKeySet) async throws -> (MainWindowController, NSWindow) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.shared.shortcutKeySet = keySet
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        let window = try #require(wc.window)
        window.orderFront(nil)
        wc.view.layoutSubtreeIfNeeded()
        try #require(await eventually(Self.wait) { wc.view.model.rows.count == 2 })
        #expect(window.makeFirstResponder(wc.view.list))
        return (wc, window)
    }

    /// A key press. Keys without ⌘ go through the window's own dispatch (`sendEvent`), which runs the menu item bound
    /// to them. AppKit offers ⌘ keys to the menu bar only for the key window, and a test window can't be key without
    /// taking the focus from whatever app is in front: the item bound to the real event runs as the menu bar runs it.
    private func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        let current = MainWindowController.currentKeyEvent
        MainWindowController.currentKeyEvent = { event }
        defer { MainWindowController.currentKeyEvent = current }
        guard flags.contains(.command) else { return window.sendEvent(event) }
        let item = try #require(MainWindowController.menuItem(for: event), "no menu item for \(characters) \(flags)")
        let wc = try #require(window.windowController as? MainWindowController)
        #expect(wc.validateMenuItem(item), "\(item.title) disabled")
        #expect(NSApp.sendAction(try #require(item.action), to: wc, from: item))
    }

    @Test(arguments: [ShortcutKeySet.mac, .dolphin]) func searchAndFilterTakeTurns(_ keySet: ShortcutKeySet) async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.file("b.txt", "b")
        let (wc, window) = try await browser(s, keySet)
        defer { window.close() }
        let pane = wc.view
        // Filter…: ⌘I with Dolphin's keys, ⌥⌘F with the Mac keys.
        let dolphin = keySet == .dolphin
        let filter = { try self.press(dolphin ? 34 : 3, dolphin ? "i" : "f", dolphin ? .command : [.command, .option], in: window) }
        let bars = { "search \(!pane.searchBar.isHidden) filter \(!pane.filterBar.isHidden) \(keySet)" }
        try press(3, "f", .command, in: window)
        #expect(!pane.searchBar.isHidden && pane.filterBar.isHidden, "\(bars())")
        // The filter bar replaces the search, and a locked filter with text is closed by the search, not hidden.
        try filter()
        #expect(pane.searchBar.isHidden && !pane.filterBar.isHidden, "\(bars())")
        pane.filterBar.isLocked = true
        pane.filterBar.set(NameFilter(text: "a", mode: .plainText))
        try #require(await eventually(Self.wait) { pane.model.rows.count == 1 })
        try press(3, "f", .command, in: window)
        #expect(!pane.searchBar.isHidden && pane.filterBar.isHidden && !pane.filterBar.isLocked, "\(keySet)")
        #expect(await eventually(Self.wait) { pane.model.rows.count == 2 })
    }

    private func capsule(_ b: BreadcrumbView) -> GlassGroup? {
        var v = b.superview
        while let s = v, !(s is GlassGroup) { v = s.superview }
        return v as? GlassGroup
    }

    /// The toolbar's Back, Forward and Up act on the active pane: its location's capsule is marked, the other isn't.
    @Test func theActivePanesLocationIsMarked() async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.file("b.txt", "b")
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        #expect(capsule(wc.tab.navigators[0])?.showsCurrent == false)
        try press(99, "\u{F706}", .function, in: window)
        try #require(await eventually(Self.wait) { wc.tab.isSplit && wc.toolbar.navigatorViews.count == 2 })
        let marks = { wc.tab.navigators.map { self.capsule($0)?.showsCurrent } }
        window.makeFirstResponder(wc.view.list)
        #expect(marks() == (wc.tab.activeIsSecondary ? [false, true] : [true, false]))
        try press(124, "\u{F703}", [.option, .numericPad, .function], in: window)
        #expect(await eventually(Self.wait) { wc.tab.activeIsSecondary }, "⌥→ focuses the right pane")
        #expect(marks() == [false, true])
        try press(123, "\u{F702}", [.option, .numericPad, .function], in: window)
        #expect(await eventually(Self.wait) { !wc.tab.activeIsSecondary })
        #expect(marks() == [true, false])
        // One pane again: nothing to tell apart.
        try press(99, "\u{F706}", .function, in: window)
        try #require(await eventually(Self.wait) { !wc.tab.isSplit })
        #expect(capsule(wc.tab.navigators[0])?.showsCurrent == false)
    }

    /// "Folder not found" keeps the status bar as it was: the free space of the disk the folder was on.
    @Test func aMissingFolderKeepsTheFreeSpace() async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        Settings.shared.statusBarMode = .fullWidth
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.file("b.txt", "b")
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        #expect(await eventually(Self.wait) { wc.view.statusBar.freeSpaceText.hasSuffix(" free") })
        wc.view.setURL(s.url.appendingPathComponent("Gone/Deeper"))
        try #require(await eventually(Self.wait) { wc.view.model.loadError != nil })
        wc.view.updateStatus()
        #expect(await eventually(Self.wait) { wc.view.statusBar.freeSpaceText.hasSuffix(" free") }, "\(wc.view.statusBar.freeSpaceText)")
    }

    @Test func theFilterBarShownAlwaysComesBackAfterTheSearch() async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        Settings.shared.showFilterBarOnStartup = true
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.file("b.txt", "b")
        let (wc, window) = try await browser(s, .mac)
        defer { window.close() }
        #expect(!wc.view.filterBar.isHidden)
        try press(3, "f", .command, in: window)
        #expect(!wc.view.searchBar.isHidden && wc.view.filterBar.isHidden)
        try press(53, "\u{1b}", in: window)
        #expect(await eventually(Self.wait) { wc.view.searchBar.isHidden && !wc.view.filterBar.isHidden })
    }
}
