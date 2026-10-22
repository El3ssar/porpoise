import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// DS-7: one set of window controls in split view, the active pane marked, an icon-only Split, a root glyph.
@Suite(.serialized, .isolatedSettings) @MainActor struct QuietChromeTests {
    init() { _ = NSApplication.shared }

    @Test func onlyTheActivePaneKeepsTheControlsAndTheEdge() throws {
        let scratch = try Scratch()
        let tab = PorpoiseTab(url: scratch.url)
        // One pane: its bar has everything, and nothing marks it.
        #expect(tab.primary.statusBar.showsControls && !tab.primary.showsActiveEdge)
        tab.openSplit(animated: false)
        let right = try #require(tab.secondary)
        #expect(right.showsActiveEdge && right.statusBar.showsControls)
        #expect(!tab.primary.showsActiveEdge && !tab.primary.statusBar.showsControls)
        tab.setActive(secondary: false)
        #expect(tab.primary.showsActiveEdge && tab.primary.statusBar.showsControls)
        #expect(!right.showsActiveEdge && !right.statusBar.showsControls)
    }

    @Test func theRootSegmentShowsWhereThePathStarts() {
        let crumb = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 400, height: 34))
        crumb.url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        #expect(crumb.rootIconName == "user-home")
        crumb.url = URL(fileURLWithPath: "/Library/Fonts")
        #expect(crumb.rootIconName == "drive-harddisk")
        crumb.url = URL(string: "sftp://example.com/home/me")!
        #expect(crumb.rootIconName == "network-server")
    }

    @Test func splitIsIconOnlyAndSaysWhatItDoes() {
        let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: 1200, height: Theme.toolbarHeight))
        toolbar.layout()
        #expect(!toolbar.split.showsTitle)
        #expect(toolbar.split.accessibilityLabel() == "Split")
    }
}
