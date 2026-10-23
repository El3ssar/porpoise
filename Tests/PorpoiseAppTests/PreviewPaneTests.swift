import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct PreviewPaneTests {
    private func text(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
    }

    private func panelItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Information", action: #selector(MainWindowController.togglePanel(_:)), keyEquivalent: "")
        item.tag = 1
        return item
    }

    @Test(arguments: ViewMode.allCases) func togglingWithLeftActiveAndChangingFocus(mode: ViewMode) async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let leftFile = try scratch.file("Left/left.txt", "left"), rightFile = try scratch.file("Right/right.txt", "right")
        let wc = MainWindowController(urls: [leftFile.deletingLastPathComponent()], split: [rightFile.deletingLastPathComponent()])
        defer { wc.window?.close() }
        let right = try #require(wc.tab.secondary)
        wc.showInformation = false
        wc.rebuildPanels()
        wc.window?.setContentSize(NSSize(width: 1500, height: 800))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        try #require(await poll { wc.tab.primary.model.rows.count == 1 && right.model.rows.count == 1 })
        for pane in wc.tab.containers {
            pane.setMode(mode)
            pane.list.select(pane === right ? rightFile : leftFile)
        }
        wc.focusLeftPane(nil)
        wc.window?.makeFirstResponder(wc.tab.primary.list)
        let share = wc.tab.splitShare, rightFrame = right.frame
        let item = panelItem()
        wc.togglePanel(item)
        #expect(wc.showInformation && wc.tab.informationPane === wc.tab.primary)
        #expect(wc.hSplit.arrangedSubviews.first === wc.tab.primary)
        #expect(right.frame == rightFrame && wc.tab.splitShare == share)
        #expect(text(in: wc.information).contains("left.txt"))
        #expect(wc.validateMenuItem(item) && item.state == .on)

        #expect(wc.window?.firstResponder === wc.tab.primary.list)
        let leftInfo = wc.information.convert(wc.information.bounds, to: wc.tab)
        #expect(leftInfo.maxX <= right.frame.minX)

        wc.focusRightPane(nil)
        #expect(wc.tab.informationPane === right && wc.hSplit.arrangedSubviews.first === right)
        #expect(text(in: wc.information).contains("right.txt"))
        #expect(wc.window?.firstResponder === right.list)
        let rightInfo = wc.information.convert(wc.information.bounds, to: wc.tab)
        #expect(rightInfo.minX >= wc.tab.primary.frame.maxX)
        #expect(wc.validateMenuItem(item) && item.state == .on)

        // Focus arriving from the file view (a click / Tab) takes the same ownership path as pane shortcuts.
        wc.window?.makeFirstResponder(wc.tab.primary.list)
        #expect(wc.view === wc.tab.primary && wc.tab.informationPane === wc.tab.primary)
        #expect(text(in: wc.information).contains("left.txt"))
        wc.focusRightPane(nil)

        // An inactive pane's hover must not replace the highlighted pane's preview.
        NotificationCenter.default.post(name: .hoverChanged, object: wc.tab.primary, userInfo: ["url": leftFile])
        try await Task.sleep(for: .milliseconds(120))
        #expect(text(in: wc.information).contains("right.txt"))
        let leftFrame = wc.tab.primary.frame
        wc.togglePanel(item)
        #expect(!wc.showInformation && wc.tab.informationHost == nil)
        #expect(wc.tab.primary.frame == leftFrame)
        #expect(wc.validateMenuItem(item) && item.state == .off)

        if mode == .columns {
            #expect(wc.tab.primary.columnBrowser?.preview.shownURL == leftFile)
            #expect(right.columnBrowser?.preview.shownURL == rightFile)
        }
    }

    @Test func rapidFocusChangesFinishTheInspectorHandoff() async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let wc = MainWindowController(urls: [scratch.url], split: [scratch.url])
        defer { wc.window?.close() }
        wc.showInformation = true
        wc.rebuildPanels()
        wc.focusRightPane(nil)
        #expect(wc.informationMoveAnimator.isRunning && wc.informationGhost != nil)
        wc.focusLeftPane(nil)
        await expectEventually { !wc.informationMoveAnimator.isRunning }
        #expect(wc.informationGhost == nil && wc.information.alphaValue == 1)
        #expect(wc.tab.informationPane === wc.tab.primary)
        #expect(wc.tab.containers.allSatisfy { $0.list.layoutWidthOverride == nil })
    }

    @Test(arguments: [ViewMode.icons, .columns]) func inspectorSurvivesAnimatedSplitChanges(mode: ViewMode) async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        for n in 0..<12 { try scratch.file("file\(n).txt", "demo") }
        let wc = MainWindowController(urls: [scratch.url])
        defer { wc.window?.close() }
        try #require(await poll { wc.view.model.rows.count == 12 })
        wc.view.setMode(mode)
        wc.showInformation = true
        wc.rebuildPanels()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.toggleSplit(nil)
        await expectEventually { !wc.tab.isSliding && wc.tab.closing == nil }
        #expect(wc.tab.informationPane === wc.view && wc.view === wc.tab.secondary)
        wc.toggleSplit(nil)
        await expectEventually { !wc.tab.isSliding && wc.tab.closing == nil }
        #expect(wc.tab.informationPane === wc.view && wc.view === wc.tab.primary)
        #expect(wc.view.list.layoutWidthOverride == nil)
    }

    @Test func thumbnailMenuTracksTheHighlightedPaneIndependentlyOfInformation() throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let wc = MainWindowController(urls: [scratch.url], split: [scratch.url])
        defer { wc.window?.close() }
        let right = try #require(wc.tab.secondary)
        var leftProps = wc.tab.primary.model.props, rightProps = right.model.props
        leftProps.previews = false
        rightProps.previews = true
        wc.tab.primary.model.props = leftProps
        right.model.props = rightProps
        wc.showInformation = false
        wc.rebuildPanels()
        let item = NSMenuItem(title: "Show Previews", action: #selector(MainWindowController.togglePreviews(_:)), keyEquivalent: "")
        wc.focusLeftPane(nil)
        #expect(wc.validateMenuItem(item) && item.state == .off)
        wc.togglePreviews(nil)
        #expect(wc.tab.primary.model.props.previews && right.model.props.previews)
        #expect(wc.validateMenuItem(item) && item.state == .on && !wc.showInformation)
        wc.focusRightPane(nil)
        wc.togglePreviews(nil)
        #expect(wc.tab.primary.model.props.previews && !right.model.props.previews)
        #expect(wc.validateMenuItem(item) && item.state == .off && !wc.showInformation)
    }

    @Test func inspectorFollowsTabsAndSurvivesClosingEitherSplit() async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let wc = MainWindowController(urls: [scratch.url], split: [scratch.url])
        defer { wc.window?.close() }
        wc.showInformation = true
        wc.rebuildPanels()
        let original = wc.tab
        wc.addTab(url: scratch.url)
        #expect(original.informationHost == nil && wc.tab.informationPane === wc.view)
        wc.showTab(0)
        #expect(wc.tab === original && original.informationPane === wc.view)
        for secondary in [false, true] {
            if !wc.tab.isSplit { wc.toggleSplit(nil) }
            if secondary { wc.focusRightPane(nil) } else { wc.focusLeftPane(nil) }
            wc.tab.closeSplit(closeActive: true, animated: false)
            wc.syncToActiveView()
            #expect(!wc.tab.isSplit && wc.tab.informationPane === wc.view)
            #expect(wc.hSplit.arrangedSubviews.count == 2 && wc.hSplit.arrangedSubviews.first === wc.view)
        }
    }
}
