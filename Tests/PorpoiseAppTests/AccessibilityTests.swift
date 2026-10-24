import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// VoiceOver and Full Keyboard Access on the custom-drawn views (UX-5): list items select, show their menu and read
/// what the view shows; column headers say how they sort; tag dots are checkboxes; collapsed path folders and tab
/// close buttons are there; toggles read on or off; Tab reaches the tab bar and the path.
@MainActor @Suite(.serialized, .isolatedSettings) struct AccessibilityTests {
    private final class Delegate: ItemListViewDelegate {
        var menus = 0
        func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) {}
        func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? {
            menus += 1
            return NSMenu(title: item?.name ?? "")
        }
        func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {}
        func itemList(_ view: ItemListView, rename item: FileItem, to name: String) {}
        func itemListDidBecomeActive(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, hovered item: FileItem?) {}
        func itemListBackgroundDoubleClicked(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, middleClicked item: FileItem) {}
        func itemListQuickLook(_ view: ItemListView) {}
    }

    private func window(_ views: [NSView]) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        for v in views { w.contentView?.addSubview(v) }
        return w
    }

    @Test func listItemsSelectShowTheirMenuAndReadWhatTheViewShows() async throws {
        let s = try Scratch()
        let tagged = try s.file("Report.txt", "hello")
        let plain = try s.file("Notes.txt", "x")
        try FinderTags.set(["Red"], on: tagged)
        let model = try await DirectoryModel.loaded(s.url) { m in
            m.props.mode = .details
            m.props.setRoles([.modificationTime, .extension_], for: .details)
        }
        let list = ItemListView(model: model)
        let delegate = Delegate()
        list.delegate = delegate
        list.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        let w = window([list])
        defer { w.orderOut(nil) }

        #expect(list.accessibilityRowCount() == 2)
        let items = try #require(list.accessibilityChildren() as? [ItemAccessibilityElement])
        let report = try #require(items.first { $0.accessibilityLabel() == "Report.txt" })
        // Tags are read in the background the first time they're asked for, as when drawing.
        _ = report.accessibilityValue()
        #expect(await eventually { (report.accessibilityValue() as? String)?.contains("Tag Red") == true })
        let value = try #require(report.accessibilityValue() as? String)
        #expect(value.contains("Modified ") && value.contains("File Extension txt"), "\(value)")

        // VO-Space: selects the item alone; deselecting removes it.
        #expect(report.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilitySelected(_:))))
        model.selection = [plain]
        report.setAccessibilitySelected(true)
        #expect(model.selection == [tagged] && report.isAccessibilitySelected())
        report.setAccessibilitySelected(false)
        #expect(model.selection.isEmpty)

        // VO-Shift-M: the item's menu, after selecting it as a right-click does.
        #expect(report.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityPerformShowMenu)))
        let i = try #require(model.index(of: tagged))
        #expect(list.accessibilityMenu(for: i)?.title == "Report.txt")
        #expect(delegate.menus == 1 && model.selection == [tagged])

        // Cut and hidden read out too.
        list.cutURLs = [tagged]
        #expect((report.accessibilityValue() as? String)?.hasSuffix(", cut") == true)
    }

    @Test func columnHeadersSaySortDirectionAndSortOnPress() async throws {
        let s = try Scratch()
        _ = try s.file("a.txt")
        let model = try await DirectoryModel.loaded(s.url) { m in
            m.props.mode = .details
            m.props.setRoles([.size, .modificationTime], for: .details)
            m.props.sortRole = .name
            m.props.sortOrder = .ascending
        }
        let list = ItemListView(model: model)
        list.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        list.computeLayout()
        let header = DetailsHeaderView(frame: CGRect(x: 0, y: 0, width: 800, height: 24))
        header.list = list
        let columns = try #require(header.accessibilityChildren() as? [DetailsColumnElement])
        #expect(columns.map { $0.accessibilityLabel() ?? "" } == ["Name", "Size", "Modified"])
        #expect(columns.allSatisfy { $0.accessibilityRole() == .button })
        #expect(columns[0].accessibilitySortDirection() == .ascending && columns[0].accessibilityValue() as? String == "sorted ascending")
        #expect(columns[1].accessibilitySortDirection() == .unknown && columns[1].accessibilityValue() == nil)
        #expect(columns[0].accessibilityPerformPress())
        #expect(model.props.sortOrder == .descending && columns[0].accessibilitySortDirection() == .descending)
        #expect(columns[1].accessibilityPerformPress())
        #expect(model.props.sortRole == .size && columns[1].accessibilitySortDirection() == .ascending)
    }

    @Test func tagDotsAreSevenCheckboxes() throws {
        var toggled: [String] = []
        let dots = TagDotsView(current: ["Red"], action: { toggled.append($0) })
        let children = try #require(dots.accessibilityChildren() as? [TagDotElement])
        #expect(children.count == 7 && children.allSatisfy { $0.accessibilityRole() == .checkBox })
        #expect(children.map { $0.accessibilityLabel() ?? "" } == FinderTags.standard.map(\.name))
        #expect((children[0].accessibilityValue() as? NSNumber)?.boolValue == true)
        #expect((children[4].accessibilityValue() as? NSNumber)?.boolValue == false)
        #expect(children[4].accessibilityPerformPress())
        #expect(toggled == ["Blue"] && (children[4].accessibilityValue() as? NSNumber)?.boolValue == true)
    }

    @Test func collapsedPathFoldersAndTabCloseButtonsAreExposed() throws {
        let crumb = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 260, height: 34))
        crumb.url = URL(fileURLWithPath: "/private/tmp/porpoise-accessibility/one/two/three/four/five")
        crumb.layout()
        let labels = (crumb.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        // Folders that don't fit collapse into "…", and are still there for VoiceOver.
        for name in ["one", "two", "three", "four", "five"] { #expect(labels.contains(name), "\(labels)") }
        // A field too narrow for more than the folder itself still lists the whole path.
        crumb.frame.size.width = 150
        crumb.layout()
        let narrow = (crumb.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(narrow == labels, "\(narrow)")

        let tabs = TabBarView(frame: CGRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        tabs.titles = ["Documents", "Downloads"]
        tabs.layout()
        let tabLabels = (tabs.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(tabLabels == ["Documents", "Close Documents", "Downloads", "Close Downloads", "New Tab"])
    }

    @Test func togglesReadOnOrOff() {
        let b = FlatButton(icon: "view-split-left-right", title: "Split")
        b.isToggled = true
        #expect(b.accessibilitySubrole() == .toggle && b.accessibilityValueDescription() == "on")
        b.isToggled = false
        #expect(b.accessibilityValueDescription() == "off")
    }

    /// With Full Keyboard Access on, Tab reaches the tab bar and the path; ←/→ move along them.
    @Test func tabReachesTheTabBarAndThePath() throws {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let tabs = TabBarView(frame: CGRect(x: 0, y: 560, width: 900, height: TabBarView.height))
        tabs.titles = ["Documents", "Downloads"]
        let crumb = BreadcrumbView(frame: CGRect(x: 0, y: 520, width: 900, height: 34))
        crumb.url = URL(fileURLWithPath: "/private/tmp/porpoise-accessibility/one")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 22))
        let w = window([tabs, crumb, field])
        defer { w.orderOut(nil) }
        tabs.layout()
        crumb.layout()
        w.orderFront(nil)
        w.recalculateKeyViewLoop()
        // The window's key-view loop, as Tab walks it.
        var reached: [String] = []
        var view: NSView? = field
        for _ in 0..<6 {
            view = view?.nextValidKeyView
            reached.append(view.map { String(describing: type(of: $0)) } ?? "nil")
        }
        #expect(reached.contains { $0.contains("TabBarView") } && reached.contains { $0.contains("BreadcrumbView") }, "\(reached)")

        #expect(w.makeFirstResponder(tabs))
        let first = tabs.focusRingMaskBounds
        tabs.keyDown(with: try key(124))
        #expect(tabs.focusRingMaskBounds != first && tabs.focusRingMaskBounds != .zero)
        #expect(w.makeFirstResponder(crumb))
        let last = crumb.focusRingMaskBounds
        crumb.keyDown(with: try key(123))
        #expect(crumb.focusRingMaskBounds != last && crumb.focusRingMaskBounds != .zero)

        // Off: they stay out of the way, as standard controls do.
        KeyboardAccess.isFull = { false }
        #expect(!tabs.acceptsFirstResponder && !crumb.acceptsFirstResponder)
    }

    /// In a browser window, Tab goes through Places, the path in the title bar and the tab bar, and back to the list;
    /// ⇧Tab goes back the same way. Hidden bars' buttons are skipped.
    @Test func tabOrderInTheBrowserWindowIncludesThePath() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let s = try Scratch()
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        let w = try #require(wc.window)
        defer { w.close() }
        _ = wc.addTab(url: s.url, select: false)
        w.orderFront(nil)
        w.layoutIfNeeded()
        func name(_ r: NSResponder?) -> String { r.map { String(describing: type(of: $0)) } ?? "nil" }
        #expect(w.makeFirstResponder(wc.view.list))
        let stops = wc.keyLoop.count
        var forward: [String] = []
        for _ in 0..<stops {
            w.selectNextKeyView(nil)
            forward.append(name(w.firstResponder))
        }
        // Reading order: the sidebar, the toolbar with the path, the tab bar, then back to the list.
        let places = forward.firstIndex(of: "PlacesPanel"), path = forward.firstIndex(of: "BreadcrumbView")
        let tabs = forward.firstIndex(of: "TabBarView")
        #expect(places != nil && path != nil && tabs != nil && places! < path! && path! < tabs!, "\(forward)")
        #expect(forward.last == "ItemListView", "\(forward)")
        var backward: [String] = []
        for _ in 0..<stops {
            w.selectPreviousKeyView(nil)
            backward.append(name(w.firstResponder))
        }
        #expect(Array(backward.dropLast().reversed()) == Array(forward.dropLast()), "\(backward)")
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
