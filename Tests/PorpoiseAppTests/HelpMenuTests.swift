import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Every Help item does something: the shortcuts sheet, the install guide, a bug report, the website, donations.
@MainActor @Suite(.serialized, .isolatedSettings) struct HelpMenuTests {
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

    /// Every icon a menu names exists in the bundled theme: the menu bar, the toolbar's menu, and the context menus
    /// of a file, a folder, an app and the background.
    @Test func everyMenuIconExists() throws {
        _ = NSApplication.shared
        NSMenuItem.missingIcons = []
        _ = AppDelegate.shared.buildMainMenu()
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let folder = scratch.url.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tab = PorpoiseTab(url: scratch.url)
        let controller = MainWindowController(window: nil)
        controller.tabs = [tab]
        _ = controller.hamburgerMenu()
        let app = FileItem(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), name: "Calculator.app", isDirectory: true)
        for item in [
            FileItem(url: file, name: "note.txt", isDirectory: false), FileItem(url: folder, name: "Folder", isDirectory: true), app, nil,
        ] {
            _ = controller.contextMenu(for: item, in: tab.primary)
        }
        #expect(NSMenuItem.missingIcons.isEmpty, "no icon for: \(NSMenuItem.missingIcons.sorted())")
    }
}
