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
        #expect(
            items.map(\.title) == [
                "Keyboard Shortcuts", "Install Guide", "Report a Bug…", "Porpoise Website", "Export Diagnostics…",
                "Support Porpoise (Donate)…",
            ])
        for item in items {
            let action = try #require(item.action, "\(item.title)")
            #expect(AppDelegate.shared.responds(to: action), "\(item.title)")
            #expect(item.image != nil, "\(item.title) has an icon")
        }
        #expect(URL(string: AppInfo.installGuide)?.host == "porpoise.dev" && AppInfo.newIssue.hasSuffix("/issues/new/choose"))
    }

    @Test func bugReportUsesTheAppsOneDiagnosticStore() throws {
        let operation = DiagnosticCorrelation()
        Diagnostics.shared.record(.helperUnavailable, failure: .unavailable, correlation: operation)
        let draft = try BugReportDraft(store: Diagnostics.shared)
        #expect(draft.diagnostics.text.contains("helper.unavailable"))
        #expect(draft.issueURL(repository: AppInfo.repository).absoluteString.hasPrefix("https://github.com/El3ssar/porpoise/issues/new?"))
    }
}
