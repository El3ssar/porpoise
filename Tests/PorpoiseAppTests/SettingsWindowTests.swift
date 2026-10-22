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

    @Test(.isolatedSettings) func opensOnGeneralThenOnThePageShownLast() throws {
        let first = SettingsWindowController()
        defer { first.window?.close() }
        let tabs = try pages(first)
        #expect(
            tabs.tabViewItems.map(\.label) == [
                "General", "Appearance", "View", "Panels", "Terminal", "Search", "Accounts", "Activity", "Shortcuts", "Advanced",
            ])
        #expect(tabs.tabViewItems[tabs.selectedTabViewItemIndex].label == "General")
        tabs.selectedTabViewItemIndex = 4
        #expect(Settings.store.string(forKey: SettingsWindowController.lastPageKey) == "Terminal")
        let again = SettingsWindowController()
        defer { again.window?.close() }
        let reopened = try pages(again)
        #expect(reopened.tabViewItems[reopened.selectedTabViewItemIndex].label == "Terminal")
        // A page that no longer exists (an older version's "Bars & Panels"): General.
        Settings.store.set("Bars & Panels", forKey: SettingsWindowController.lastPageKey)
        let renamed = SettingsWindowController()
        defer { renamed.window?.close() }
        let fallback = try pages(renamed)
        #expect(fallback.tabViewItems[fallback.selectedTabViewItemIndex].label == "General")
        // A page asked for (the Activity window's Transfer Rules) wins over the one shown last.
        let asked = SettingsWindowController(page: "Activity")
        defer { asked.window?.close() }
        let activity = try pages(asked)
        #expect(activity.tabViewItems[activity.selectedTabViewItemIndex].label == "Activity")
    }
}
