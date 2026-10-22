import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Full Keyboard Access in a browser window (UX-6): Tab goes through a defined order that includes the title bar and
/// the panels shown; Esc leaves the terminal at its prompt; ⇧F10 opens the item menu; the zoom glyphs are buttons;
/// the Focus actions reach Folders, Information and the Shelf.
@MainActor @Suite(.serialized, .isolatedSettings) struct KeyLoopTests {
    private func browser(_ s: Scratch) throws -> MainWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        wc.window?.orderFront(nil)
        return wc
    }

    private func name(_ r: NSResponder?) -> String {
        guard let v = MainWindowController.focusedView(r) ?? (r as? NSView) else { return "nil" }
        return String(describing: type(of: v))
    }

    @Test func tabGoesThroughSidebarLocationListInformationAndTerminalAndBack() throws {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let s = try Scratch()
        _ = try s.file("a.txt")
        let wc = try browser(s)
        let w = try #require(wc.window)
        defer { w.close() }
        wc.showInformation = true
        wc.showTerminal = true
        wc.rebuildPanels()
        // A shown terminal has started its shell; here its view is put in place without one.
        wc.terminal.addSubview(wc.terminal.terminalView)
        wc.terminal.terminalView.frame = wc.terminal.bounds.insetBy(dx: 4, dy: 3)
        w.layoutIfNeeded()

        let loop = wc.keyLoop.map { String(describing: type(of: $0)) }
        func at(_ name: String) -> Int? { loop.firstIndex { $0.contains(name) } }
        let order = ["PlacesPanel", "BreadcrumbView", "ItemListView", "InformationPanel", "LocalProcessTerminalView"].map(at)
        #expect(order.allSatisfy { $0 != nil }, "\(loop)")
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "\(loop)")
        // The toolbar's buttons and the status bar's zoom glyphs are stops too, with Full Keyboard Access.
        #expect(loop.contains("FlatButton") && loop.contains("ZoomGlyph"), "\(loop)")

        // Tab from the list walks the whole loop and comes back; ⇧Tab goes the other way.
        #expect(w.makeFirstResponder(wc.view.list))
        var walked: [String] = []
        for _ in loop {
            w.selectNextKeyView(nil)
            walked.append(name(w.firstResponder))
        }
        #expect(walked.last == "ItemListView" && walked.contains("InformationPanel") && walked.contains("LocalProcessTerminalView"), "\(walked)")
        w.selectPreviousKeyView(nil)
        #expect(name(w.firstResponder) == loop[(loop.firstIndex(of: "ItemListView")! + loop.count - 1) % loop.count])

        // Esc at the terminal's prompt: back to the list.
        #expect(w.makeFirstResponder(wc.terminal.terminalView))
        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        w.sendEvent(esc)
        #expect(w.firstResponder === wc.view.list)
        // Esc anywhere else is left alone.
        #expect(!wc.leaveTerminalOnEscape(esc))
    }

    @Test func hiddenPanelsAndControlsWithoutFullKeyboardAccessArentStops() throws {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { false }
        let s = try Scratch()
        let wc = try browser(s)
        let w = try #require(wc.window)
        defer { w.close() }
        wc.showInformation = false
        wc.showTerminal = false
        wc.rebuildPanels()
        w.layoutIfNeeded()
        let loop = wc.keyLoop.map { String(describing: type(of: $0)) }
        #expect(loop.contains("ItemListView") && loop.contains("PlacesPanel"))
        for gone in ["InformationPanel", "TerminalView", "BreadcrumbView", "FlatButton", "ZoomGlyph", "TabBarView"] {
            #expect(!loop.contains { $0.contains(gone) }, "\(gone): \(loop)")
        }
    }

    @Test func focusActionsShowThePanelAndToggleBack() throws {
        let s = try Scratch()
        let wc = try browser(s)
        let w = try #require(wc.window)
        defer { w.close() }
        wc.showInformation = false
        wc.rebuildPanels()
        #expect(w.makeFirstResponder(wc.view.list))
        wc.focusInformation(nil)
        #expect(wc.showInformation && w.firstResponder === wc.information)
        wc.focusInformation(nil)
        #expect(w.firstResponder === wc.view.list)
        wc.focusFolders(nil)
        #expect(wc.showFolders)
        #expect(MainWindowController.focusedView(w.firstResponder)?.isDescendant(of: wc.folders) == true)
    }

    @Test func shiftF10OpensTheCurrentItemsMenu() async throws {
        let s = try Scratch()
        let file = try s.file("Report.txt")
        let wc = try browser(s)
        let w = try #require(wc.window)
        defer { w.close() }
        #expect(await eventually { wc.view.model.index(of: file) != nil })
        let list = wc.view.list
        list.computeLayout()
        wc.view.model.currentURL = file
        let shown = try #require(list.keyboardMenu())
        #expect(wc.view.model.selection == [file])
        let i = try #require(wc.view.model.index(of: file))
        #expect(shown.at == CGPoint(x: list.frames[i].midX, y: list.frames[i].midY))
        #expect(shown.menu.items.contains { !$0.isSeparatorItem })
    }

    @Test func zoomGlyphsAreButtons() {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        var steps = 0
        let g = ZoomGlyph(large: true)
        g.onClick = { steps += 1 }
        #expect(g.accessibilityRole() == .button && g.accessibilityLabel() == "Larger Icons")
        #expect(g.accessibilityPerformPress() && steps == 1)
        KeyboardAccess.isFull = { false }
        #expect(!g.acceptsFirstResponder)
        KeyboardAccess.isFull = { true }
        #expect(g.acceptsFirstResponder)
    }
}
