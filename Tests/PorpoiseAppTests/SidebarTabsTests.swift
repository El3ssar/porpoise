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

    /// Folders shown after navigating with Places shown selects the folder the window shows (the tree learns the
    /// location when its tab comes, not only at the next navigation), and keeps following from there.
    @Test func theFoldersTabSelectsTheFolderShown() async throws {
        let s = try Scratch()
        try s.folder("Projects/Porpoise/Sources/Panels")
        let (wc, window) = try browser(s)
        defer { window.close() }
        func selected() -> String? {
            let outline = (wc.folders.subviews.first as? NSScrollView)?.documentView as? NSOutlineView
            return outline.flatMap { ($0.item(atRow: $0.selectedRow) as? FoldersPanel.Node)?.name }
        }
        // Once with Folders never shown, once after it was shown somewhere else.
        for (i, target) in ["Projects/Porpoise/Sources/Panels", "Projects/Porpoise"].enumerated() {
            wc.view.setURL(s.path(target))
            try #require(await eventually { wc.view.url.lastPathComponent == s.path(target).lastPathComponent })
            wc.chooseSidebarTab(.folders)
            try #require(await eventually { selected() == s.path(target).lastPathComponent }, "pass \(i): \(selected() ?? "none")")
            wc.chooseSidebarTab(.places)
        }
        wc.chooseSidebarTab(.folders)
        wc.view.setURL(s.path("Projects/Porpoise/Sources"))
        try #require(await eventually { selected() == "Sources" }, "\(selected() ?? "none")")
        // A change of look reloads the tree's cells (new icons): the folder stays selected.
        NotificationCenter.default.post(name: Settings.changed, object: "appearancePreferences")
        try await Task.sleep(for: .milliseconds(200))
        #expect(selected() == "Sources")
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
        // Eight levels down: the tree's column used to widen with every level expanded, past the panel's edge.
        let deep = "one/two/three/four/five/six/seven/\(long)"
        try s.folder(deep)
        Settings.shared.homeURL = s.url
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        panel.currentURL = s.path(deep)
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        try #require(await eventually { (0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name == long } })
        let row = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name == long })
        outline.layoutSubtreeIfNeeded()
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        cell.layoutSubtreeIfNeeded()
        let field = try #require(cell.textField)
        #expect(field.lineBreakMode == .byTruncatingMiddle && cell.toolTip == long)
        // The field ends inside the panel (it ran past it and was clipped with no ellipsis: a field 400 pt wide in a
        // narrower cell, and a column widened by the levels above it).
        #expect(outline.tableColumns[0].width <= outline.visibleRect.width + 0.5, "\(outline.tableColumns[0].width)")
        let fieldEnd = field.convert(field.bounds, to: outline).maxX
        #expect(fieldEnd <= outline.visibleRect.maxX + 0.5, "\(fieldEnd) > \(outline.visibleRect.maxX)")
        #expect(field.attributedStringValue.size().width > field.bounds.width, "the name should need shortening at 200 pt")
        // Eight levels in 200 pt: less indentation than the 14 pt of a shallow tree, never under 8.
        #expect(outline.indentationPerLevel < 14 && outline.indentationPerLevel >= 8, "\(outline.indentationPerLevel)")
        // Every row's name ends inside the panel, also in rows whose cells were reused at another depth.
        panel.currentURL = s.url
        try #require(await eventually { outline.selectedRow < 0 || (outline.item(atRow: outline.selectedRow) as? FoldersPanel.Node)?.url == s.url })
        outline.layoutSubtreeIfNeeded()
        for r in 0..<outline.numberOfRows {
            guard let c = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView, let f = c.textField else { continue }
            c.layoutSubtreeIfNeeded()
            #expect(f.convert(f.bounds, to: outline).maxX <= outline.visibleRect.maxX + 0.5, "row \(r)")
        }
    }

    /// A folder 14 levels down in a 230-pt sidebar with an always-shown (legacy) scroller, as Breeze or a mouse gives:
    /// the folder shown and the one above it keep a readable name, and no name runs under the scroller.
    @Test func deepTreesKeepTheShownFolderReadable() async throws {
        let s = try Scratch()
        let levels = (1...13).map { "level-\($0)-folder" }
        let deep = (levels + ["the-folder-shown-here"]).joined(separator: "/")
        try s.folder(deep)
        for i in 0..<40 { try s.folder("sibling-folder-with-a-long-name-\(i)") }
        Settings.shared.homeURL = s.url
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 230, height: 300))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        let scroll = try #require(panel.subviews.first as? NSScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let outline = try #require(scroll.documentView as? NSOutlineView)
        panel.currentURL = s.path(deep)
        try #require(await eventually { (outline.item(atRow: outline.selectedRow) as? FoldersPanel.Node)?.name == "the-folder-shown-here" })
        panel.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        #expect(scroll.verticalScroller?.isHidden == false && scroll.contentView.bounds.width < 230, "\(scroll.contentView.bounds)")
        #expect(outline.tableColumns[0].width <= scroll.contentView.bounds.width + 0.5, "\(outline.tableColumns[0].width)")
        let clipEnd = scroll.contentView.bounds.width
        for r in 0..<outline.numberOfRows {
            guard let c = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView, let f = c.textField else { continue }
            c.layoutSubtreeIfNeeded()
            #expect(f.convert(f.bounds, to: outline).maxX <= clipEnd + 0.5, "row \(r) runs under the scroller")
        }
        for (row, name) in [(outline.selectedRow, "shown"), (outline.selectedRow - 1, "its parent")] {
            let c = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            c.layoutSubtreeIfNeeded()
            #expect((c.textField?.bounds.width ?? 0) >= 70, "\(name): \(c.textField?.bounds.width ?? 0) pt for the name")
        }
    }

    /// Palette themes give the selected segment their accent only while the window is key: in an inactive window the
    /// accent fill came out darker than the other segment and read as the opposite tab.
    @Test func paletteSwitchFallsBackToAppKitWhenInactive() throws {
        let s = try Scratch()
        var prefs = Settings.shared.appearancePreferences
        prefs.themeName = "Breeze Dark"
        Settings.shared.appearancePreferences = prefs
        Theme.lookChanged()
        defer {
            Settings.shared.appearancePreferences.themeName = AppearanceTheme.systemName
            Theme.lookChanged()
        }
        let (wc, window) = try browser(s)
        defer { window.close() }
        #expect(!Tokens.isNative && !window.isKeyWindow)
        #expect(wc.navigator.picker.selectedSegmentBezelColor == nil)
        // The window becoming key or not is followed.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(wc.navigator.picker.selectedSegmentBezelColor == nil)
    }

    /// A hairline under the switch while the tab's list is scrolled away from its top, none at the top.
    @Test func anEdgeShowsUnderTheSwitchWhenTheListIsScrolled() throws {
        let s = try Scratch()
        let (wc, window) = try browser(s)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 420))
        window.layoutIfNeeded()
        let nav = wc.navigator
        #expect(nav.edge.isHidden && !nav.contentIsScrolled)
        let clip = wc.placesScroll.contentView
        let doc = try #require(wc.placesScroll.documentView)
        try #require(doc.bounds.height > clip.bounds.height, "Places should need scrolling at 420 pt: \(doc.bounds.height)")
        doc.scroll(doc.isFlipped ? NSPoint(x: 0, y: doc.bounds.maxY) : .zero)
        #expect(nav.contentIsScrolled && !nav.edge.isHidden)
        #expect(abs(nav.edge.frame.maxY - (nav.picker.frame.minY - Tokens.Space.s)) < 0.5 && nav.edge.frame.height == 1)
        doc.scroll(doc.isFlipped ? .zero : NSPoint(x: 0, y: doc.bounds.maxY))
        #expect(nav.edge.isHidden)
    }

    /// A hidden folder on the way to the shown one is in the tree anyway, and stays there, open, when a change on disk
    /// lists its parent again (it was dropped with everything below it, and the shown folder lost its row).
    @Test func revealedHiddenFoldersSurviveARelist() async throws {
        let s = try Scratch()
        try s.folder(".hidden/inner")
        Settings.shared.homeURL = s.url
        Settings.shared.foldersShowHidden = false
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        panel.watchesDisk = false
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        func names() -> [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name } }
        func selected() -> String? { (outline.item(atRow: outline.selectedRow) as? FoldersPanel.Node)?.name }
        panel.currentURL = s.path(".hidden/inner")
        try #require(await eventually { selected() == "inner" }, "\(names())")
        try s.folder("Later")
        panel.foldersChanged([s.url.path])
        try #require(await eventually { names().contains("Later") }, "\(names())")
        #expect(names() == [".hidden", "inner", "Later"] && selected() == "inner", "\(names()) \(selected() ?? "none")")
        // Gone from the disk, it goes from the tree too.
        try FileManager.default.removeItem(at: s.path(".hidden"))
        panel.foldersChanged([s.url.path])
        try #require(await eventually { !names().contains(".hidden") }, "\(names())")
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
        try #require(
            await eventually { selected().map(real) == real(s.path("Inner/Deeper")) },
            "\((0..<outline.numberOfRows).map { (outline.item(atRow: $0) as? FoldersPanel.Node)?.url.path ?? "?" }) selected \(outline.selectedRow) home \(Settings.shared.homeURL.path)"
        )
        // A change on disk lists Home again (here a late event about the folders just made): the shown folder stays
        // selected through the reload.
        try s.folder("Later")
        panel.foldersChanged([s.url.path])
        try #require(await eventually { (0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? FoldersPanel.Node)?.name == "Later" } })
        #expect(selected().map(real) == real(s.path("Inner/Deeper")), "selected row \(outline.selectedRow)")
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
