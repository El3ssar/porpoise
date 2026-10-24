import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Places and Folders are two tabs of the sidebar's navigator, each at its full height: the switch at its top, F9 and
/// F7 (real key events), View › Show Panels and Focus Folders pick a tab; the tab is kept in the session and in
/// layouts, also while the sidebar is hidden.
@MainActor @Suite(.serialized, .isolatedSettings) struct SidebarTabsTests {
    private func browser(_ s: Scratch, _ keySet: ShortcutKeySet = .mac) throws -> (MainWindowController, NSWindow) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.shared.shortcutKeySet = keySet
        Settings.shared.homeURL = s.url
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFront(nil)
        wc.showShelf = false
        wc.showPlaces = true
        wc.rebuildPanels()
        window.layoutIfNeeded()
        return (wc, window)
    }

    /// The sidebar's parts, top to bottom, by type.
    private func parts(_ wc: MainWindowController) -> [String] { wc.leftStack.arrangedSubviews.map { String(describing: type(of: $0)) } }

    private func expectFullHeight(_ wc: MainWindowController, _ content: NSView, _ comment: Comment? = nil) {
        let nav = wc.navigator
        #expect(nav.content === content && content.superview === nav, comment)
        #expect(nav.frame.height == wc.leftStack.bounds.height, comment)
        // All of the navigator below its switch: 8 pt above and below the switch, nothing else.
        #expect(abs(content.frame.height - (nav.bounds.height - nav.picker.frame.height - Tokens.Space.s * 2)) < 0.5, comment)
        #expect(content.frame.minY == 0 && content.frame.width == nav.bounds.width, comment)
    }

    @Test func eachTabTakesTheWholeSidebar() throws {
        let s = try Scratch()
        let (wc, window) = try browser(s)
        defer { window.close() }
        #expect(parts(wc) == ["SidebarNavigator"])
        #expect(wc.navigator.picker.selectedSegment == 0 && wc.navigator.picker.controlSize == .small)
        expectFullHeight(wc, wc.placesScroll)
        wc.showFolders = true
        #expect(wc.showFolders && !wc.showPlaces && wc.sidebarTab == .folders)
        wc.rebuildPanels()
        window.layoutIfNeeded()
        expectFullHeight(wc, wc.folders)
        #expect(wc.placesScroll.window == nil && wc.navigator.picker.selectedSegment == 1)
        // With the Shelf the navigator keeps the top, still one tab at a time.
        wc.showShelf = true
        wc.rebuildPanels()
        #expect(parts(wc) == ["SidebarNavigator", "ShelfPanel"])
        #expect(wc.navigator.content === wc.folders && wc.placesScroll.window == nil)
    }

    /// F9 and F7 as real key events through the window's dispatch (the menu item bound to each key runs): the
    /// hidden tab's key shows it in place, the shown tab's key hides the sidebar, and it comes back on the tab asked for.
    @Test(arguments: [ShortcutKeySet.mac, .dolphin]) func functionKeysPickTheTab(_ keySet: ShortcutKeySet) throws {
        let previous = NSApplication.shared.mainMenu
        defer { NSApp.mainMenu = previous }
        let s = try Scratch()
        let (wc, window) = try browser(s, keySet)
        defer { window.close() }
        #expect(window.makeFirstResponder(wc.view.list))
        let sidebarWidth = wc.sidebar.frame.width
        func press(_ f: Int) throws {
            let key = String(UnicodeScalar(UInt16(NSF1FunctionKey + f - 1))!)
            let codes = [7: UInt16(98), 9: 101]
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                    keyCode: codes[f]!))
            let item = try #require(MainWindowController.menuItem(for: event), "F\(f) finds no menu item")
            #expect(item.action == #selector(MainWindowController.togglePanel(_:)) && item.tag == (f == 9 ? 0 : 2))
            let current = MainWindowController.currentKeyEvent
            MainWindowController.currentKeyEvent = { event }
            defer { MainWindowController.currentKeyEvent = current }
            // In the active app the menu bar takes the key first. The test runner is never active and has no key window,
            // so NSApp.sendEvent drops it; the window's own dispatch then offers it to the menu (`performMenuKey`).
            window.sendEvent(event)
            wc.finishPanelSlide()
            window.layoutIfNeeded()
        }
        try press(7)
        #expect(wc.showFolders && !wc.showPlaces)
        // In place: the sidebar didn't slide or change width, the files kept the focus.
        #expect(wc.sidebar.superview != nil && wc.sidebar.frame.width == sidebarWidth)
        #expect(window.firstResponder === wc.view.list)
        expectFullHeight(wc, wc.folders)
        try press(7)
        #expect(!wc.showFolders && !wc.showPlaces && wc.sidebarTab == .folders)
        #expect(wc.outer.arrangedSubviews.first !== wc.sidebar)
        try press(9)
        #expect(wc.showPlaces && wc.outer.arrangedSubviews.first === wc.sidebar)
        expectFullHeight(wc, wc.placesScroll)
        try press(9)
        #expect(!wc.showNavigator && wc.sidebarTab == .places)
        try press(7)
        #expect(wc.showFolders)
        expectFullHeight(wc, wc.folders)
    }

    /// A click on the switch (its action, as the control's tracking sends it) shows that tab; the menu's checkmarks
    /// follow. The control ignores made-up mouse and key events in an app that isn't active (the test runner), so F9
    /// and F7 above are the real-event path into the same code.
    @Test func theSwitchShowsTheTab() throws {
        let s = try Scratch()
        let (wc, window) = try browser(s)
        defer { window.close() }
        let picker = wc.navigator.picker
        func choose(_ segment: Int) {
            picker.selectedSegment = segment
            #expect(picker.sendAction(picker.action, to: picker.target))
        }
        func checked() -> [String] {
            MainWindowController.panelsMenu().items.filter { $0.action == #selector(MainWindowController.togglePanel(_:)) && !$0.isHidden }.filter {
                _ = wc.validateMenuItem($0)
                return $0.state == .on
            }.map(\.title)
        }
        choose(1)
        #expect(wc.showFolders && picker.selectedSegment == 1)
        expectFullHeight(wc, wc.folders)
        #expect(checked().contains("Folders") && !checked().contains("Places"), "\(checked())")
        choose(0)
        #expect(wc.showPlaces && picker.selectedSegment == 0)
        expectFullHeight(wc, wc.placesScroll)
        #expect(checked().contains("Places") && !checked().contains("Folders"), "\(checked())")
    }

    /// Switching tabs while the focus is in the tab that leaves gives it to the one that comes.
    @Test func focusFollowsTheTab() throws {
        let s = try Scratch()
        let (wc, window) = try browser(s)
        defer { window.close() }
        #expect(window.makeFirstResponder(wc.places))
        wc.chooseSidebarTab(.folders)
        #expect(MainWindowController.focusedView(window.firstResponder)?.isDescendant(of: wc.folders) == true)
        wc.focusPlaces(nil)
        #expect(wc.showPlaces && window.firstResponder === wc.places)
    }

    /// The tab is part of the window's layout (session, workspaces), also while the sidebar is hidden; layouts from
    /// before the tabs read as before.
    @Test func theTabIsKeptInLayouts() throws {
        let s = try Scratch()
        let (wc, window) = try browser(s)
        defer { window.close() }
        wc.showFolders = true
        wc.showFolders = false
        wc.rebuildPanels()
        var layout = wc.captureLayout()
        #expect(layout.panels.sidebarTab == "folders" && !layout.panels.places && !layout.panels.folders)
        let decoded = try JSONDecoder().decode(WindowLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded.panels.sidebarTab == "folders")
        wc.showPlaces = true
        wc.rebuildPanels()
        #expect(wc.applyLayout(decoded))
        #expect(!wc.showNavigator && wc.sidebarTab == .folders)
        // Shown again (View › Show Panels › Folders would do it), on the kept tab.
        wc.showFolders = true
        #expect(wc.showFolders)
        // A layout saved before the tabs: Folders alone is its tab; both panels start on Places.
        layout.panels = try JSONDecoder().decode(PanelLayout.self, from: Data(#"{"places":false,"folders":true}"#.utf8))
        #expect(wc.applyLayout(layout))
        #expect(wc.showFolders && wc.sidebarTab == .folders)
        layout.panels = try JSONDecoder().decode(PanelLayout.self, from: Data(#"{"places":true,"folders":true}"#.utf8))
        #expect(wc.applyLayout(layout))
        #expect(wc.showPlaces && !wc.showFolders)
        #expect(Settings.store.string(forKey: "panel.sidebarTab") == "places")
    }

    /// Long names in the Folders tree are shortened in the middle, inside their row, and the tooltip has them whole.
    @Test func longFolderNamesTruncateInTheMiddle() async throws {
        let s = try Scratch()
        let long = "-Users-someone-Projects-a-rather-long-project-name-ending-in-42"
        try s.folder(long)
        Settings.shared.homeURL = s.url
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        panel.currentURL = s.url
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        try #require(await eventually { (0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name == long } })
        let row = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name == long })
        outline.layoutSubtreeIfNeeded()
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        cell.layoutSubtreeIfNeeded()
        let field = try #require(cell.textField)
        #expect(field.lineBreakMode == .byTruncatingMiddle && cell.toolTip == long)
        // The field ends inside the row (it used to run 400 pt past it and be clipped with no ellipsis).
        let fieldEnd = field.convert(field.bounds, to: outline).maxX
        #expect(fieldEnd <= outline.visibleRect.maxX + 0.5, "\(fieldEnd) > \(outline.visibleRect.maxX)")
        #expect(field.attributedStringValue.size().width > field.bounds.width, "the name should need shortening at 200 pt")
    }

    /// "Limit to Home folder": inside Home the tree starts there; outside it, at the top of the disk (as Dolphin).
    @Test func limitToHomeStartsAtHomeOnlyInsideIt() async throws {
        let s = try Scratch()
        try s.folder("Inner/Deeper")
        let outside = try Scratch()
        try outside.folder("Elsewhere")
        Settings.shared.homeURL = s.url
        Settings.shared.foldersLimitToHome = true
        let testing = Settings.isTesting
        Settings.isTesting = true
        defer { Settings.isTesting = testing }
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        func topName() -> String? { (outline.item(atRow: 0) as? FoldersPanel.Node)?.url.path }
        func selected() -> URL? { (outline.item(atRow: outline.selectedRow) as? FoldersPanel.Node)?.url }
        func real(_ u: URL) -> String { FilePath.canonical(u.path) }
        panel.currentURL = s.path("Inner/Deeper")
        try #require(await eventually { selected().map(real) == real(s.path("Inner/Deeper")) })
        // The root itself isn't a row: Home's children are the top rows.
        #expect(outline.parent(forItem: outline.item(atRow: 0)) == nil && topName().map { URL(fileURLWithPath: $0).lastPathComponent } == "Inner")
        panel.currentURL = outside.path("Elsewhere")
        try #require(await eventually { selected().map(real) == real(outside.path("Elsewhere")) })
        #expect(topName().map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } == "/")
        // Off: the top of the disk inside Home too.
        Settings.shared.foldersLimitToHome = false
        panel.currentURL = s.path("Inner")
        try #require(await eventually { selected().map(real) == real(s.path("Inner")) })
        #expect(topName().map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } == "/")
    }
}
