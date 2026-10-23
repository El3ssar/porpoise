import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// The line between the two panes of a split tab behaves like a thin native divider: drags stop at the panes'
/// minimum width, a window resize keeps them too, double-click returns to halves, grabbing it mid-slide leaves the
/// panes laid out at their real widths, and it looks like the window's other hairlines (W-214).
@Suite(.serialized, .isolatedSettings) @MainActor final class SplitDividerTests {
    private func settle(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult private func settle(until condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(eventualTimeout)
        while !condition() {
            guard Date() < end else { return false }
            try await settle(0.05)
        }
        return true
    }

    /// A split tab `width` wide in a window, both panes listed.
    private func splitTab(_ folder: URL, width: CGFloat = 1100, animated: Bool = false) async throws -> (NSWindow, PorpoiseTab) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = PorpoiseTab(url: folder)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        try await settle { !tab.primary.model.isLoading && !tab.primary.model.rows.isEmpty }
        tab.layoutSubtreeIfNeeded()
        tab.openSplit(animated: animated)
        // Reopening goes back to where the line was last left (another test's drag): start at halves.
        tab.setSplitShare(0.5)
        tab.layoutSubtreeIfNeeded()
        return (window, tab)
    }

    private func folder(_ scratch: Scratch, files: Int = 6) throws -> URL {
        for n in 1...files { try Data("\(n)".utf8).write(to: scratch.url.appendingPathComponent("file \(n).txt")) }
        return scratch.url
    }

    /// The line's x in the tab (the left pane's width).
    private func lineX(_ tab: PorpoiseTab) -> CGFloat { tab.primary.frame.maxX }

    /// The view a press at `x` (tab coordinates) lands on: the window's own hit-testing. Drags and the release go to
    /// it too, as the window sends them (an off-screen test window doesn't route mouse events itself).
    private var pressed: NSView?

    private func mouse(_ type: NSEvent.EventType, at x: CGFloat, in tab: PorpoiseTab, clicks: Int = 1) {
        guard let window = tab.window else { return }
        let p = tab.convert(CGPoint(x: x, y: tab.bounds.midY), to: nil)
        guard
            let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        else { return }
        switch type {
        case .leftMouseDown:
            pressed = window.contentView?.superview?.hitTest(p)
            pressed?.mouseDown(with: e)
        case .leftMouseDragged: pressed?.mouseDragged(with: e)
        default:
            pressed?.mouseUp(with: e)
            pressed = nil
        }
    }

    private func drag(_ tab: PorpoiseTab, to x: CGFloat) {
        let from = lineX(tab) + 0.5
        mouse(.leftMouseDown, at: from, in: tab)
        for i in 1...8 { mouse(.leftMouseDragged, at: from + (x - from) * CGFloat(i) / 8, in: tab) }
        mouse(.leftMouseUp, at: x, in: tab)
    }

    @Test func layoutKeepsBothPanesAtTheirMinimum() {
        let w: CGFloat = 1100, min = SplitLayout.minPaneWidth
        #expect(SplitLayout.range(in: w) == min...(w - min - 1))
        #expect(SplitLayout.lineX(fraction: 0.5, in: w) == 550)
        #expect(SplitLayout.lineX(fraction: 0.01, in: w) == min)
        #expect(SplitLayout.lineX(fraction: 0.99, in: w) == w - min - 1)
        #expect(SplitLayout.directions(atX: min, in: w) == .right)
        #expect(SplitLayout.directions(atX: w - min - 1, in: w) == .left)
        #expect(SplitLayout.directions(atX: 550, in: w) == .both)
        // Too narrow for both minimums: the panes share the width.
        #expect(SplitLayout.range(in: 300) == nil)
        #expect(SplitLayout.lineX(fraction: 0.1, in: 300) == 150)
    }

    @Test func dragStopsAtTheMinimumsAndTheCursorSaysWhichWayIsLeft() async throws {
        let scratch = try Scratch()
        let (window, tab) = try await splitTab(try folder(scratch))
        defer { window.close() }
        let w = tab.bounds.width
        #expect(lineX(tab) == (w / 2).rounded())
        #expect(tab.handle.directions == .both)

        drag(tab, to: 300)
        #expect(lineX(tab) == 300)
        #expect(tab.secondary?.frame.minX == 301 && tab.secondary?.frame.maxX == w)
        drag(tab, to: 20)
        #expect(lineX(tab) == SplitLayout.minPaneWidth)
        #expect(tab.handle.directions == .right)
        #expect(tab.handle.cursor == NSCursor.columnResize(directions: .right))
        drag(tab, to: w)
        #expect(lineX(tab) == w - SplitLayout.minPaneWidth - 1)
        #expect(tab.secondary?.frame.width == SplitLayout.minPaneWidth)
        #expect(tab.handle.directions == .left)
        #expect(tab.handle.cursor == NSCursor.columnResize(directions: .left))
    }

    /// 7 pt to grab: the line and 3 pt each side; beyond that the panes get the clicks.
    @Test func theGrabAreaIsSevenPoints() async throws {
        let scratch = try Scratch()
        let (window, tab) = try await splitTab(try folder(scratch))
        defer { window.close() }
        let x = lineX(tab)
        func hit(_ dx: CGFloat) -> NSView? {
            let p = tab.convert(CGPoint(x: x + 0.5 + dx, y: tab.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(p)
        }
        for dx in [-3.0, -1, 0, 1, 3] { #expect(hit(dx) === tab.handle, "dx \(dx)") }
        for dx in [-4.0, 4] { #expect(hit(dx) !== tab.handle, "dx \(dx)") }
        #expect(tab.handle.acceptsFirstMouse(for: nil))
        #expect(!tab.handle.mouseDownCanMoveWindow)
    }

    /// A narrower window keeps both panes usable and gives the line back its place when it widens again; too narrow
    /// for both, the panes share it.
    @Test func windowResizeKeepsTheMinimumsAndComesBack() async throws {
        let scratch = try Scratch()
        let (window, tab) = try await splitTab(try folder(scratch))
        defer { window.close() }
        drag(tab, to: 330)
        let share = tab.splitShare
        for width in [900.0, 600, 400] {
            tab.setFrameSize(NSSize(width: width, height: tab.bounds.height))
            tab.layoutSubtreeIfNeeded()
            let left = tab.primary.frame.width, right = tab.secondary?.frame.width ?? 0
            #expect(left >= SplitLayout.minPaneWidth && right >= SplitLayout.minPaneWidth, "width \(width): \(left) | \(right)")
            #expect(left + 1 + right == CGFloat(width))
            #expect(tab.splitShare == share)
        }
        tab.setFrameSize(NSSize(width: 300, height: tab.bounds.height))
        tab.layoutSubtreeIfNeeded()
        #expect(tab.primary.frame.width == 150 && tab.secondary?.frame.width == 149)
        tab.setFrameSize(NSSize(width: 1100, height: tab.bounds.height))
        tab.layoutSubtreeIfNeeded()
        #expect(lineX(tab) == 330)
    }

    /// Double-click returns to halves; the double-click's press moving a little doesn't drag the line away again.
    @Test func doubleClickResetsAndIsNoDrag() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let (window, tab) = try await splitTab(try folder(scratch))
        defer { window.close() }
        drag(tab, to: 300)
        #expect(lineX(tab) == 300)
        let x = lineX(tab) + 0.5
        mouse(.leftMouseDown, at: x, in: tab)
        mouse(.leftMouseUp, at: x, in: tab)
        mouse(.leftMouseDown, at: x, in: tab, clicks: 2)
        #expect(tab.splitShare == 0.5)
        mouse(.leftMouseDragged, at: x + 40, in: tab, clicks: 2)
        mouse(.leftMouseUp, at: x + 40, in: tab, clicks: 2)
        #expect(tab.splitShare == 0.5)
        #expect(lineX(tab) == (tab.bounds.width / 2).rounded())
    }

    /// Grabbing the line while the split slides open ends the slide with what its end puts in place: both lists are
    /// laid out at their own widths again (they were left at the slide's widths).
    @Test func grabbingTheSlideLeavesThePanesAtTheirWidths() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        FrameClock.frameStep = 1.0 / 60
        defer { FrameClock.frameStep = nil }
        let scratch = try Scratch()
        let url = try folder(scratch)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: url)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        tab.primary.setMode(.icons)
        try await settle { !tab.primary.model.isLoading && tab.primary.model.rows.count == 6 }
        tab.layoutSubtreeIfNeeded()

        tab.openSplit()
        #expect(tab.isSliding)
        #expect(tab.primary.list.layoutWidthOverride != nil)
        try await settle { lineX(tab) < tab.bounds.width - 150 }
        #expect(tab.isSliding)
        drag(tab, to: 400)
        #expect(!tab.isSliding)
        #expect(lineX(tab) == 400)
        let right = try #require(tab.secondary)
        let released = try await settle {
            tab.primary.list.layoutWidthOverride == nil && right.list.layoutWidthOverride == nil && right.list.transitionHidden.isEmpty
        }
        let overrides = (tab.primary.list.layoutWidthOverride, right.list.layoutWidthOverride)
        #expect(released, "width overrides left \(String(describing: overrides.0)), right \(String(describing: overrides.1))")
        #expect(abs(tab.primary.list.visibleWidth - tab.primary.listWidth(forPaneWidth: 400)) < 1)
    }

    /// The line is the window's hairline, in a layer (moving it draws nothing), and VoiceOver can find and move it.
    @Test func looksLikeAHairlineAndIsASplitter() async throws {
        let scratch = try Scratch()
        let (window, tab) = try await splitTab(try folder(scratch))
        defer { window.close() }
        var hairline: CGColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { hairline = Theme.hairline.cgColor }
        #expect(tab.handle.lineColor == hairline)
        #expect(tab.handle.frame.width == SplitDividerView.width && tab.handle.frame.height == tab.bounds.height)
        #expect(tab.handle.accessibilityRole() == .splitter)
        #expect((tab.handle.accessibilityValue() as? NSNumber)?.doubleValue == 0.5)
        let before = lineX(tab)
        #expect(tab.handle.accessibilityPerformIncrement())
        #expect(lineX(tab) == before + (tab.bounds.width / 20).rounded())
        #expect(tab.handle.accessibilityPerformDecrement())
        #expect(lineX(tab) == before)
    }
}
