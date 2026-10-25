import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct SettingsWindowTests {
    init() { _ = NSApplication.shared }

    private func pages(_ controller: SettingsWindowController) throws -> NSTabViewController {
        try #require(controller.window?.contentViewController as? NSTabViewController)
    }

    private func label(_ tabs: NSTabViewController) -> String { tabs.tabViewItems[tabs.selectedTabViewItemIndex].label }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    /// The page's section headings, top to bottom.
    private func headings(_ tabs: NSTabViewController, _ page: String) throws -> [String] {
        let item = try #require(tabs.tabViewItems.first { $0.label == page })
        let doc = try #require((item.viewController?.view as? NSScrollView)?.documentView)
        doc.layoutSubtreeIfNeeded()
        return Self.views(in: doc).compactMap { v -> (String, CGFloat)? in
            guard let t = v as? NSTextField, !t.isHiddenOrHasHiddenAncestor, t.identifier == FormBuilder.headingID else { return nil }
            return (t.stringValue, t.convert(t.bounds, to: doc).minY)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The page's control (check box, radio, button, pop-up) with this title or item.
    private func control(_ tabs: NSTabViewController, _ page: String, _ title: String) throws -> NSControl {
        let item = try #require(tabs.tabViewItems.first { $0.label == page })
        let doc = try #require((item.viewController?.view as? NSScrollView)?.documentView)
        return try #require(
            Self.views(in: doc).compactMap { $0 as? NSControl }.first {
                ($0 as? NSPopUpButton)?.itemTitles.contains(title) == true || ($0 as? NSButton)?.title == title
            })
    }

    @Test(.isolatedSettings) func opensOnGeneralThenOnThePageShownLast() throws {
        let first = SettingsWindowController()
        defer { first.window?.close() }
        let tabs = try pages(first)
        #expect(
            tabs.tabViewItems.map(\.label) == [
                "General", "Appearance", "Views", "Sidebar & Bars", "Files", "Accounts & Servers", "Keyboard", "Advanced",
            ])
        #expect(label(tabs) == "General")
        // Titled after its page from the start, as after a change of page.
        #expect(first.window?.title == "General")
        tabs.selectedTabViewItemIndex = 4
        #expect(Settings.store.string(forKey: SettingsWindowController.lastPageKey) == "Files")
        let again = SettingsWindowController()
        defer { again.window?.close() }
        let reopened = try pages(again)
        #expect(label(reopened) == "Files")
        #expect(again.window?.title == "Files")
        // A page that no longer exists: General.
        Settings.store.set("Bars & Toolbars", forKey: SettingsWindowController.lastPageKey)
        let gone = SettingsWindowController()
        defer { gone.window?.close() }
        #expect(label(try pages(gone)) == "General")
        // A page asked for wins over the one shown last.
        let asked = SettingsWindowController(page: "Keyboard")
        defer { asked.window?.close() }
        #expect(label(try pages(asked)) == "Keyboard")
    }

    /// A page of an earlier version, shown last or asked for by its old name, opens the page its settings went to.
    @Test(.isolatedSettings) func oldPageNamesOpenTheirNewPage() throws {
        let moves = [
            "View": "Views", "Panels": "Sidebar & Bars", "Bars & Panels": "Sidebar & Bars", "Activity": "Files", "Accounts": "Accounts & Servers",
            "Shortcuts": "Keyboard", "Custom Tools": "Keyboard", "Terminal": "Advanced", "Search": "Advanced",
        ]
        for (old, new) in moves {
            Settings.store.set(old, forKey: SettingsWindowController.lastPageKey)
            let shownLast = SettingsWindowController()
            defer { shownLast.window?.close() }
            #expect(label(try pages(shownLast)) == new, "shown last: \(old)")
            let asked = SettingsWindowController(page: old)
            defer { asked.window?.close() }
            #expect(label(try pages(asked)) == new, "asked for: \(old)")
        }
    }

    /// Every page groups what a Mac user looks for there; the sections of the old eleven pages are all on one of them.
    @Test(.isolatedSettings) func eachPageHoldsItsSections() throws {
        let w = SettingsWindowController()
        defer { w.window?.close() }
        let tabs = try pages(w)
        #expect(try headings(tabs, "General") == ["Show on startup", "Windows", "Tabs", "Split view", "Default file browser", "Updates"])
        #expect(
            try headings(tabs, "Views") == [
                "Display style", "Browsing", "Items", "Content display", "Icons", "Compact", "Details", "Show previews for", "Preview size limits",
            ])
        #expect(
            try headings(tabs, "Sidebar & Bars") == [
                "Folders panel", "Information panel", "Status bar", "Location bar", "Filter bar", "Show in context menus",
            ])
        #expect(
            try headings(tabs, "Files") == [
                "Ask for confirmation when", "Trash", "Copies and moves", "Transfer rules", "Name clashes", "Archives", "Compare files",
            ])
        let accounts = try headings(tabs, "Accounts & Servers")
        #expect(accounts.first == "Accounts and servers" && accounts.last == "Sign-in configuration", "\(accounts)")
        #expect(try headings(tabs, "Keyboard") == ["Key set", "Keyboard shortcuts", "Toolbar", "Custom tools"])
        let advanced = try headings(tabs, "Advanced")
        for section in [
            "Terminal panel", "Shell", "External terminal", "Instant search", "Command-line tool", "Android phones", "Permissions", "Reset",
        ] {
            #expect(advanced.contains(section), "Advanced has \(section)")
        }
        #expect(advanced.last == "Reset")
    }

    /// Moved controls still change the setting they always changed (the stored keys stay, so existing preferences hold).
    @Test(.isolatedSettings) func movedControlsKeepTheirSettings() throws {
        let w = SettingsWindowController()
        defer { w.window?.close() }
        let tabs = try pages(w)
        let s = Settings.shared
        let filterBar = s.showFilterBarOnStartup
        try control(tabs, "Sidebar & Bars", "Always show filter bar").performClick(nil)
        #expect(s.showFilterBarOnStartup == !filterBar)
        let archives = s.browseArchives
        try control(tabs, "Files", "Browse compressed files as folders").performClick(nil)
        #expect(s.browseArchives == !archives)
        let library = s.appLibraryView
        try control(tabs, "Views", "Show Applications as an app library").performClick(nil)
        #expect(s.appLibraryView == !library)
        let leftovers = s.reviewAppLeftovers
        try control(tabs, "Files", "Review an app's leftover files when it's moved to the Trash").performClick(nil)
        #expect(s.reviewAppLeftovers == !leftovers)
        // Restore All Defaults is still on Advanced.
        _ = try control(tabs, "Advanced", "Restore All Defaults")
        // A setting changed elsewhere shows on its new page.
        s.browseArchives = archives
        #expect((try control(tabs, "Files", "Browse compressed files as folders") as? NSButton)?.state == (archives ? .on : .off))
    }

    /// The Activity window's Transfer Rules…, Tools › Custom Tools… and Porpoise › Permissions… open their page with
    /// their section scrolled to the top.
    @Test(.isolatedSettings) func aSectionAskedForIsScrolledIntoView() throws {
        let w = SettingsWindowController()
        let window = try #require(w.window)
        defer { window.close() }
        let tabs = try pages(w)
        for (page, section) in [("Files", "Transfer rules"), ("Keyboard", "Custom tools"), ("Advanced", SettingsPages.permissionsSection)] {
            w.show(page: page, section: section)
            #expect(label(tabs) == page)
            let scroll = try #require(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view as? NSScrollView)
            let doc = try #require(scroll.documentView)
            let heading = try #require(SettingsWindowController.heading(section, in: doc))
            let frame = heading.convert(heading.bounds, to: doc)
            #expect(scroll.contentView.bounds.contains(frame), "\(section) is visible on \(page)")
            #expect(scroll.contentView.bounds.minY > 0, "\(page) scrolled down to \(section)")
        }
    }

    @Test func accountsAndServersSummary() {
        #expect(AccountsSettingsPage.summary(0, 0) == "No cloud accounts or servers yet")
        #expect(AccountsSettingsPage.summary(1, 0) == "1 cloud account, 0 servers")
        #expect(AccountsSettingsPage.summary(2, 1) == "2 cloud accounts, 1 server")
    }

    /// Settings › Accounts & Servers opens the one Accounts & Servers window.
    @Test(.isolatedSettings) func theAccountsPageOpensTheAccountsAndServersWindow() throws {
        let w = SettingsWindowController(page: "Accounts & Servers")
        defer { w.window?.close() }
        let tabs = try pages(w)
        AccountsServersWindow.current?.window?.close()
        try control(tabs, "Accounts & Servers", "Open Accounts & Servers…").performClick(nil)
        let shown = try #require(AccountsServersWindow.current?.window)
        defer { shown.close() }
        #expect(shown.isVisible && shown.title == "Accounts & Servers")
    }
}
