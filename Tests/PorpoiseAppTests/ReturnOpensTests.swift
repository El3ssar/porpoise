import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Return in the file list does what its key set says: Open with Dolphin's keys, Rename with the Mac keys. The key
/// presses go through AppKit's own dispatch (`NSApp.sendEvent`), which offers the menu bar only keys with ⌘ or ⌃: a
/// bare Return reaches the list even though File › Open (or Rename) shows it.
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
    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
}
