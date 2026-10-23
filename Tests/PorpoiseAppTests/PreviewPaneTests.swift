import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct PreviewPaneTests {
    private final class AttachmentProbe: NSView {
        var detachments = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detachments += 1 }
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

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
        #expect(wc.hSplit.arrangedSubviews.first === wc.informationSpace && wc.tab.primary.superview === wc.tab)
        #expect(right.frame == rightFrame && wc.tab.splitShare == share)
        #expect(text(in: wc.information).contains("left.txt"))
        #expect(wc.validateMenuItem(item) && item.state == .on)

        #expect(wc.window?.firstResponder === wc.tab.primary.list)
        let leftInfo = wc.information.convert(wc.information.bounds, to: wc.tab)
        #expect(leftInfo.maxX <= right.frame.minX)
        wc.toolbar.layoutSubtreeIfNeeded()
        let ranges = wc.tab.paneRanges
        let slot = wc.hSplit.convert(wc.hSplit.bounds, to: nil)
        #expect(ranges[0] == slot.minX...slot.maxX)
        #expect(abs(ranges[1].lowerBound - ranges[0].upperBound - SplitDividerView.lineWidth) < 0.5)
        for (index, navigator) in wc.tab.navigators.enumerated() {
            let frame = navigator.convert(navigator.bounds, to: nil)
            #expect(frame.minX >= ranges[index].lowerBound && frame.maxX <= ranges[index].upperBound)
        }

        wc.focusRightPane(nil)
        #expect(wc.tab.informationPane === right && right.superview === wc.tab)
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
        let probe = AttachmentProbe()
        wc.information.addSubview(probe)
        let window = wc.information.window
        var attached = true
        var frames: [CGRect] = []
        wc.toggleSplit(nil)
        await expectEventually {
            attached = attached && wc.information.window === window && wc.hSplit.superview === wc.tab
            frames.append(wc.information.convert(wc.information.bounds, to: wc.tab))
            return !wc.tab.isSliding && wc.tab.closing == nil
        }
        #expect(wc.tab.informationPane === wc.view && wc.view === wc.tab.secondary)
        wc.toggleSplit(nil)
        await expectEventually {
            attached = attached && wc.information.window === window && wc.hSplit.superview === wc.tab
            frames.append(wc.information.convert(wc.information.bounds, to: wc.tab))
            return !wc.tab.isSliding && wc.tab.closing == nil
        }
        #expect(wc.tab.informationPane === wc.view && wc.view === wc.tab.primary)
        #expect(wc.view.list.layoutWidthOverride == nil)
        #expect(attached && probe.detachments == 0 && Set(frames.map(\.minX)).count > 2)
    }

    @Test func inspectorLayoutPreservesScrollTypingHoverAndDetailsHeader() async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        for n in 0..<100 { try scratch.file(String(format: "file%03d.txt", n), "demo") }
        let wc = MainWindowController(urls: [scratch.url], split: [scratch.url])
        defer { wc.window?.close() }
        wc.showInformation = false
        wc.rebuildPanels()
        let left = wc.tab.primary, right = try #require(wc.tab.secondary)
        try #require(await poll { left.model.rows.count == 100 && right.model.rows.count == 100 })
        for pane in wc.tab.containers { pane.setMode(.details) }
        left.list.columnWidths[.name] = 1200
        left.list.relayout()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let probes = wc.tab.containers.map { pane in
            let probe = AttachmentProbe()
            pane.addSubview(probe)
            return probe
        }
        left.restoreScroll(to: CGPoint(x: 80, y: 300))
        right.restoreScroll(to: CGPoint(x: 0, y: 500))
        let origins = [left.scrollOrigin, right.scrollOrigin]
        let columns = left.list.columnWidths
        left.list.typeAhead = "file0"
        left.list.typeAheadTime = Date()
        left.list.hoverIndex = 20
        let hovered = left.list.hoveredURL
        wc.window?.makeFirstResponder(left.list)
        let item = panelItem()
        for _ in 0..<3 {
            wc.togglePanel(item)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            for pane in wc.tab.containers {
                let point = wc.tab.convert(CGPoint(x: pane.scroll.bounds.midX, y: pane.scroll.bounds.midY), from: pane.scroll)
                #expect(wc.tab.hitTest(point)?.isDescendant(of: pane) == true)
            }
            wc.focusRightPane(nil)
            wc.focusLeftPane(nil)
            wc.togglePanel(item)
        }
        #expect(probes.allSatisfy { $0.detachments == 0 })
        #expect(left.superview === wc.tab && right.superview === wc.tab)
        #expect(left.scrollOrigin == origins[0] && right.scrollOrigin == origins[1])
        #expect(left.list.typeAhead == "file0" && left.list.hoveredURL == hovered)
        #expect(left.list.columnWidths == columns && left.header.list === left.list && !left.header.isHidden)
        #expect(left.header.scrollX == left.scroll.contentView.bounds.minX)
        left.list.updateTrackingAreas()
        let tracking = try #require(left.list.trackingArea)
        #expect(left.list.trackingAreas.contains(tracking) && tracking.options.contains(.inVisibleRect))
        #expect(wc.window?.firstResponder === left.list)
        // A menu toggle during inline editing must leave the same field editor, draft and selection in place.
        left.list.beginRename(left.model.rows[20].item.url)
        let field = try #require(left.list.renameField)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "draft-name.txt"
        editor.selectedRange = NSRange(location: 2, length: 4)
        wc.togglePanel(item)
        wc.togglePanel(item)
        #expect(left.list.renameField === field && wc.window?.firstResponder === editor)
        #expect(editor.string == "draft-name.txt" && editor.selectedRange == NSRange(location: 2, length: 4))
        left.list.cancelRename()
    }

    @Test func playingColumnVideoStaysAttachedAcrossInspectorAndFocusChanges() async throws {
        _ = NSApplication.shared
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let video = scratch.url.appendingPathComponent("demo.mp4")
        try FileManager.default.copyItem(at: TestPaths.fixtures.appendingPathComponent("Videos/h264.mp4"), to: video)
        let wc = MainWindowController(urls: [scratch.url], split: [scratch.url])
        defer { wc.window?.close() }
        wc.showInformation = false
        wc.rebuildPanels()
        wc.focusLeftPane(nil)
        let left = wc.view
        try #require(await poll { left.model.rows.count == 1 })
        left.setMode(.columns)
        left.layoutSubtreeIfNeeded()
        left.list.select(video)
        let column = try #require(left.columnBrowser?.preview)
        try #require(await poll { descendant(AVPlayerView.self, in: column)?.player?.currentItem?.status == .readyToPlay })
        let player = try #require(descendant(AVPlayerView.self, in: column)?.player)
        let currentItem = try #require(player.currentItem)
        let probe = AttachmentProbe()
        column.addSubview(probe)
        player.play()
        try #require(await poll { player.timeControlStatus == .playing })
        let time = player.currentTime()
        wc.togglePanel(panelItem())
        wc.focusRightPane(nil)
        wc.focusLeftPane(nil)
        wc.togglePanel(panelItem())
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.detachments == 0 && column.shownURL == video)
        #expect(descendant(AVPlayerView.self, in: column)?.player === player && player.currentItem === currentItem)
        #expect(player.currentTime() >= time && player.rate > 0)
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
            #expect(wc.hSplit.arrangedSubviews.count == 2 && wc.view.superview === wc.tab)
        }
    }
}
