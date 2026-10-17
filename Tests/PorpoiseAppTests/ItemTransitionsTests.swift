import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

/// Every item animation goes through one coordinator per view: a split runs one transition per pane, whatever the
/// listing does meanwhile, and nothing animates twice.
@Suite(.serialized) @MainActor struct ItemTransitionsTests {
    private func settle(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aSplitRunsOneTransitionPerPaneAndChangesWaitForIt() async throws {
        _ = NSApplication.shared
        let suite = "app.porpoise.transitions-test.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        let previousStore = Settings.store, previousTesting = Settings.isTesting
        Settings.store = store
        Settings.isTesting = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            Settings.store = previousStore
            Settings.isTesting = previousTesting
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...6 { try Data("\(n)".utf8).write(to: folder.appendingPathComponent("file \(n).txt")) }

        // What the machine is set to (CI's runner reduces motion) must not decide what this test sees.
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: folder)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        tab.primary.setMode(.icons)
        for _ in 0..<600 where tab.primary.model.rows.count < 6 { try await settle(0.05) }
        #expect(tab.primary.model.rows.count == 6)
        tab.layoutSubtreeIfNeeded()

        tab.openSplit()
        let right = try #require(tab.secondary)
        // Settled: the right pane listed its folder, the flight landed and the pane has its real width (each is an
        // event the test waits for, however slow the machine).
        #expect(
            tab.primary.list.transitions.animates, "window \(String(describing: tab.primary.list.window)), visible \(tab.primary.list.visibleRect)")
        func settled() -> Bool {
            right.model.rows.count == 6 && right.list.transitionHidden.isEmpty && right.list.layoutWidthOverride == nil
                && right.list.transitions.log == [.splitOpen]
        }
        for _ in 0..<600 where !settled() { try await settle(0.05) }
        #expect(right.model.rows.count == 6)
        #expect(right.list.transitions.log == [.splitOpen])
        #expect(tab.primary.list.transitions.log.filter { $0 == .splitOpen }.count == 1)
        #expect(right.list.transitionHidden.isEmpty && right.list.layoutWidthOverride == nil)

        // While a flight is due or running, a change shows at once instead of animating on its own.
        let t = right.list.transitions
        t.navigate()
        var arrived = false
        t.whenItemsArrive { arrived = true }
        #expect(!arrived)
        t.change(.remote) {}
        t.itemsDelivered(loading: false)
        #expect(arrived && t.log == [.splitOpen])
        t.flightStarts(hiding: [])
        t.change(.remote) {}
        t.resized()
        #expect(t.log == [.splitOpen, .splitOpen])
        t.flightCancelled()
        t.change(.filter) {}
        #expect(t.log.last == .filter)

        // Reduce Motion: nothing moves.
        Animator.reducesMotion = { true }
        t.change(.filter) {}
        #expect(t.log == [.splitOpen, .splitOpen, .filter] && !t.animates)

        tab.closeSplit(closeActive: true)
        try await settle(0.6)
        #expect(tab.secondary == nil && tab.primary.list.layoutWidthOverride == nil)
    }

    /// Opening the split on a pane zoomed bigger (or smaller), and closing it again: the flying copies change size
    /// smoothly from the leaving pane's to the landing pane's (never jumping at the end), and land as the very items
    /// drawn there, which show in the same frame the copies go.
    @Test(arguments: [ViewMode.icons, .compact, .details], [true, false])
    func flightsTurnIntoTheLandingPanesSize(mode: ViewMode, bigger: Bool) async throws {
        _ = NSApplication.shared
        let suite = "app.porpoise.flight-test.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        let previousStore = Settings.store, previousTesting = Settings.isTesting
        Settings.store = store
        Settings.isTesting = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer {
            Animator.reducesMotion = reduces
            Settings.store = previousStore
            Settings.isTesting = previousTesting
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...4 { try Data("\(n)".utf8).write(to: folder.appendingPathComponent("file \(n).txt")) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: folder)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        tab.primary.setMode(mode)
        for _ in 0..<600 where tab.primary.model.rows.count < 4 { try await settle(0.05) }
        tab.layoutSubtreeIfNeeded()
        func flown() async throws -> PorpoiseTab.FlightRecord? {
            for _ in 0..<600 where tab.secondary.map({ !$0.list.transitionHidden.isEmpty || $0.list.layoutWidthOverride != nil }) ?? false {
                try await settle(0.05)
            }
            try await settle(0.2)
            return tab.lastFlight
        }

        // The right pane's own zoom, saved for the folder: the left one keeps the size it shows.
        tab.openSplit()
        let right = try #require(tab.secondary)
        _ = try await flown()
        var props = right.model.props
        let size = props.iconSize(for: mode)
        props.setIconSize(bigger ? size * 2 : max(16, size / 2), for: mode)
        right.model.props = props
        right.model.saveProps()
        tab.closeSplit(closeActive: true)
        try await settle(0.6)

        tab.openSplit()
        let opened = try #require(try await flown(), "no flight")
        let left = tab.primary.list, reopened = try #require(tab.secondary).list
        #expect(reopened.iconSize != left.iconSize, "\(reopened.iconSize) vs \(left.iconSize)")
        #expect(opened.isSmooth, "\(opened.sizes) → \(String(describing: opened.landing))")
        #expect(opened.shownWhenCopiesWent && opened.sizes.count > 2)
        if let first = opened.sizes.first, let landing = opened.landing {
            #expect(bigger ? landing.height > first.height : landing.height < first.height, "\(first) → \(landing)")
        }

        // Closing the pane zoomed so: back to the left pane's size, as smoothly.
        tab.setActive(secondary: true)
        tab.closeSplit(closeActive: true)
        for _ in 0..<40 { try await settle(0.05) }
        let closed = try #require(tab.lastFlight)
        #expect(closed.isSmooth, "\(closed.sizes) → \(String(describing: closed.landing))")
        #expect(closed.shownWhenCopiesWent && tab.primary.list.transitionHidden.isEmpty)
    }
}
