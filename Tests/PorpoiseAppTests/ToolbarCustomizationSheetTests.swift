import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Customize Toolbar opens on the browser window whose toolbar it changes, as a sheet (as Finder's palette drops from
/// its own toolbar), and closes with Done, Return or Escape. Keys go to the sheet through its own dispatch.
@MainActor @Suite(.serialized, .isolatedSettings) struct ToolbarCustomizationSheetTests {
    /// Settles in well under a second; a failure must not hold a shared build lane for minutes.
    static let wait: TimeInterval = 5

    private func editor() -> NSWindow? {
        NSApp.windows.first { $0.windowController is ToolbarCustomizationWindow && $0.isVisible }
    }

    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }

    private func browser(_ s: Scratch) throws -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppDelegate.shared.newWindow(at: s.url)
        let window = try #require(AppDelegate.shared.windows.last?.window)
        window.orderFront(nil)
        return window
    }

    /// Closes the palette AppKit opened on the editor as the user does, with its Done button, so the editor's own keys
    /// reach it.
    private func closePalette(on sheet: NSWindow) async {
        func buttons(_ v: NSView?) -> [NSButton] { (v as? NSButton).map { [$0] } ?? (v?.subviews ?? []).flatMap(buttons) }
        if let palette = sheet.attachedSheet, let done = buttons(palette.contentView).first(where: { $0.title == "Done" }) { done.performClick(nil) }
        _ = await eventually(Self.wait) { sheet.attachedSheet == nil && sheet.toolbar?.customizationPaletteIsRunning != true }
    }

    /// No editor outlives its test (the next one would find it open).
    private func closeEditors() {
        for w in NSApp.windows where w.windowController is ToolbarCustomizationWindow {
            w.sheetParent?.endSheet(w)
            w.close()
        }
    }

    @Test(arguments: [(UInt16(36), "\r"), (UInt16(53), "\u{1b}")]) func itIsASheetOnTheBrowserWindow(_ key: (UInt16, String)) async throws {
        let s = try Scratch()
        let window = try browser(s)
        defer { closeEditors(); window.close() }
        ToolbarCustomizationWindow.show()
        let sheet = try #require(await eventually(Self.wait) { self.editor() != nil } ? editor() : nil)
        #expect(sheet.sheetParent === window && window.attachedSheet === sheet)
        // The palette drops from the sheet's toolbar, as from Finder's own.
        #expect(await eventually(Self.wait) { sheet.toolbar?.customizationPaletteIsRunning == true })
        await closePalette(on: sheet)
        #expect(sheet.attachedSheet == nil, "palette still attached")
        try press(key.0, key.1, in: sheet)
        #expect(await eventually(Self.wait) { window.attachedSheet == nil && self.editor() == nil }, "\(key.1.debugDescription) closes it")
    }

    /// The layout chosen in the editor is kept when it closes, and every browser window shows it.
    @Test func changesStayAfterDone() async throws {
        let s = try Scratch()
        let window = try browser(s)
        defer { closeEditors(); window.close() }
        ToolbarCustomizationWindow.show()
        let sheet = try #require(await eventually(Self.wait) { self.editor() != nil } ? editor() : nil)
        await closePalette(on: sheet)
        #expect(sheet.attachedSheet == nil, "palette still attached")
        let layout: [ToolbarCommand] = [.back, .forward, .location, .search]
        sheet.toolbar?.itemIdentifiers = layout.map(\.toolbarIdentifier)
        try press(36, "\r", in: sheet)
        #expect(await eventually(Self.wait) { Settings.shared.toolbarCommands == layout })
    }

    /// Opened from Settings with no browser window open: a window of its own, as before.
    @Test func withoutABrowserWindowItIsAWindow() async throws {
        closeEditors()
        for w in NSApp.windows where w.windowController is MainWindowController { w.close() }
        #expect(ToolbarCustomizationWindow.browserWindow == nil)
        defer { closeEditors() }
        ToolbarCustomizationWindow.show()
        let editor = try #require(await eventually(Self.wait) { self.editor() != nil } ? editor() : nil)
        defer { editor.close() }
        #expect(editor.sheetParent == nil)
    }
}
