import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Return in the file list does what its key set says: Open with Dolphin's keys, Rename with the Mac keys; and every
/// other menu key without ⌘ or ⌃ runs its item. The key presses go through AppKit's own dispatch (`NSApp.sendEvent`),
/// which offers the menu bar only keys with ⌘, ⌃ or a function key: a bare Return, ⌥↩ or ⌥2 reaches the window.
@MainActor @Suite(.serialized, .isolatedSettings) struct ReturnOpensTests {
    enum Layout: CaseIterable { case single, split, panels }

    private struct Browser {
        let wc: MainWindowController
        let window: NSWindow
        var opened: () -> [String]
    }

    /// A browser window on `Inner/` and `a.txt`, with the key set's menu bar, in `mode` and `layout`. Files it opens
    /// are only recorded.
    private func browser(_ s: Scratch, _ keySet: ShortcutKeySet, _ mode: ViewMode, _ layout: Layout) async throws -> Browser {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.shared.shortcutKeySet = keySet
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        let window = try #require(wc.window)
        window.orderFront(nil)
        var opened: [String] = []
        wc.localFileOpening.open = { opened.append($0.lastPathComponent) }
        if layout == .split, mode != .columns { wc.toggleSplit(nil) }
        if layout == .panels {
            wc.showInformation = true
            wc.showFolders = true
            wc.rebuildPanels()
        }
        wc.show(mode)
        wc.view.layoutSubtreeIfNeeded()
        try #require(await eventually { wc.view.model.rows.count == 2 })
        #expect(window.makeFirstResponder(wc.view.list))
        return Browser(wc: wc, window: window, opened: { opened })
    }

    private func select(_ name: String, in b: Browser) throws {
        let url = try #require(b.wc.view.model.rows.first { $0.item.name == name }?.item.url)
        b.wc.view.list.select(url)
    }

    /// A key press as the system delivers it: AppKit's current event while it's dispatched, then `NSApp.sendEvent`.
    private func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        let current = MainWindowController.currentKeyEvent
        MainWindowController.currentKeyEvent = { event }
        defer { MainWindowController.currentKeyEvent = current }
        NSApp.sendEvent(event)
    }

    @Test(arguments: ViewMode.allCases, Layout.allCases) func dolphinsReturnOpensTheSelection(_ mode: ViewMode, _ layout: Layout) async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.file("Inner/b.txt", "b")
        let b = try await browser(s, .dolphin, mode, layout)
        defer { b.window.close() }
        try select("a.txt", in: b)
        try press(36, "\r", in: b.window)
        try #require(await eventually { b.opened() == ["a.txt"] }, "\(mode) \(layout): \(b.opened())")
        // The keypad's Enter opens too.
        try press(76, "\u{3}", in: b.window)
        try #require(await eventually { b.opened() == ["a.txt", "a.txt"] }, "\(mode) \(layout): \(b.opened())")
        // A folder: Return goes into it (Column view: into its column, where Return opens the file there).
        try select("Inner", in: b)
        if mode == .columns {
            try press(124, "\u{F703}", in: b.window)
            try #require(await eventually { b.wc.view.model.rows.contains { $0.item.name == "b.txt" } })
            try select("b.txt", in: b)
            try press(36, "\r", in: b.window)
            try #require(await eventually { b.opened().last == "b.txt" }, "\(b.opened())")
        } else {
            try press(36, "\r", in: b.window)
            #expect(await eventually { b.wc.view.url.lastPathComponent == "Inner" }, "\(mode) \(layout): \(b.wc.view.url.path)")
        }
    }

    /// The Mac keys: Return renames the selection (Finder), and opens nothing.
    @Test(arguments: ViewMode.allCases) func macReturnRenames(_ mode: ViewMode) async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.folder("Inner")
        let b = try await browser(s, .mac, mode, .single)
        defer { b.window.close() }
        try select("a.txt", in: b)
        try press(36, "\r", in: b.window)
        #expect(await eventually { b.window.firstResponder is NSTextView }, "\(mode): \(String(describing: b.window.firstResponder))")
        #expect(b.opened().isEmpty)
        b.window.makeFirstResponder(b.wc.view.list)
    }

    /// Every menu key without ⌘ or ⌃, in both key sets, runs its item from the file list when the item is enabled there
    /// (a split, a file selected): walked from the menu bar, so a new binding is covered too. Function keys (F2, ⌦, the
    /// arrows) take AppKit's key-equivalent path to the menu bar, as ⌘ keys do; the test runner's app has none, so for
    /// them the item must be the one the key finds and be enabled.
    @Test(arguments: [ShortcutKeySet.mac, .dolphin]) func everyMenuKeyWithoutCommandRunsItsItem(_ keySet: ShortcutKeySet) async throws {
        let previous = NSApplication.shared.mainMenu, send = MainWindowController.sendMenuAction
        defer { NSApp.mainMenu = previous; MainWindowController.sendMenuAction = send }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.folder("Inner")
        let b = try await browser(s, keySet, .icons, .split)
        defer { b.window.close() }
        try select("a.txt", in: b)
        var ran: [Selector] = []
        MainWindowController.sendMenuAction = { action, _, _ in
            ran.append(action); return true
        }
        func all(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let keys = all(try #require(NSApp.mainMenu)).filter {
            $0.action != nil && !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.intersection([.command, .control]).isEmpty
        }
        #expect(keys.count > 20, "\(keys.map(\.title))")
        var dead: [String] = [], typed = 0
        for item in keys {
            #expect(b.window.makeFirstResponder(b.wc.view.list))
            ran = []
            let key = item.keyEquivalent, flags = item.keyEquivalentModifierMask
            let function = key.utf16.first.map { $0 >= 0xF700 && $0 <= 0xF8FF } == true
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: function ? flags.union(.function) : flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: b.window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "\r" ? 36 : 0))
            let current = MainWindowController.currentKeyEvent
            MainWindowController.currentKeyEvent = { event }
            defer { MainWindowController.currentKeyEvent = current }
            let found = MainWindowController.menuItem(for: event)
            #expect(found?.action == item.action, "\(item.title) finds \(found?.title ?? "nothing")")
            guard let found, b.wc.validateMenuItem(found) else { continue }
            if function { continue }
            typed += 1
            NSApp.sendEvent(event)
            if ran != [item.action!] { dead.append("\(item.title) \(key.unicodeScalars.map { String($0.value, radix: 16) }) \(flags.rawValue)") }
        }
        #expect(typed >= 10 && dead.isEmpty, "\(keySet): \(dead)")
    }

    /// What some of those keys do, for real: ⌥2 and ⌥1 go to those tabs, Dolphin's ⌥↩ shows Get Info.
    @Test func menuKeysWithoutCommandDoTheirJob() async throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        _ = try s.file("a.txt", "a")
        _ = try s.folder("Inner")
        let b = try await browser(s, .dolphin, .icons, .single)
        defer { b.window.close() }
        b.wc.newTab(nil)
        b.wc.newTab(nil)
        #expect(b.wc.current == 2)
        #expect(b.window.makeFirstResponder(b.wc.view.list))
        try press(19, "2", [.option], in: b.window)
        #expect(b.wc.current == 1)
        #expect(b.window.makeFirstResponder(b.wc.view.list))
        try press(18, "1", [.option], in: b.window)
        #expect(b.wc.current == 0)
        #expect(b.window.makeFirstResponder(b.wc.view.list))
        try select("a.txt", in: b)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        try press(36, "\r", [.option], in: b.window)
        let shown = await eventually { NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) && $0 is PropertiesPanel } }
        #expect(shown)
        for w in NSApp.windows where !before.contains(ObjectIdentifier(w)) && w is PropertiesPanel { w.close() }
    }
}
