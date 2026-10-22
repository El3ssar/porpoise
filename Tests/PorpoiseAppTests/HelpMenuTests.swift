import AppKit
import PorpoiseServices
import Testing

@testable import Porpoise

/// Every Help item does something: the shortcuts sheet, the install guide, a bug report, the website, donations.
@MainActor struct HelpMenuTests {
    @Test func helpItemsReachRealActions() throws {
        _ = NSApplication.shared
        let menu = AppDelegate.shared.buildMainMenu()
        let help = try #require(menu.items.first { $0.title == "Help" }?.submenu)
        let items = help.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Keyboard Shortcuts", "Install Guide", "Report a Bug…", "Porpoise Website", "Support Porpoise (Donate)…"])
        for item in items {
            let action = try #require(item.action, "\(item.title)")
            #expect(AppDelegate.shared.responds(to: action), "\(item.title)")
            #expect(item.image != nil, "\(item.title) has an icon")
        }
        #expect(URL(string: AppInfo.installGuide)?.host == "porpoise.dev" && AppInfo.newIssue.hasSuffix("/issues/new/choose"))
    }

    @Test func bugReportShowsTheExactDiagnosticsReadOnly() throws {
        let draft = try BugReportDraft(store: BugReportDialog.diagnostics)
        let scroll = try #require(BugReportDialog.preview(draft.diagnostics.text) as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string == draft.diagnostics.text && !text.isEditable && text.isSelectable)
        #expect(draft.diagnostics.text.contains("\"schemaVersion\""))
    }
}
