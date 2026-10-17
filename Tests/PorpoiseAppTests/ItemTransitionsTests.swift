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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: folder)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        tab.primary.setMode(.icons)
        for _ in 0..<100 where tab.primary.model.rows.count < 6 { try await settle(0.02) }
        #expect(tab.primary.model.rows.count == 6)
        tab.layoutSubtreeIfNeeded()

        tab.openSplit()
        let right = try #require(tab.secondary)
        // Settled: the flight landed and the pane has its real width (slower under coverage and a busy machine).
        for _ in 0..<50 where !right.list.transitionHidden.isEmpty || right.list.layoutWidthOverride != nil { try await settle(0.1) }
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
        let reduces = ItemTransitions.reducesMotion
        ItemTransitions.reducesMotion = { true }
        defer { ItemTransitions.reducesMotion = reduces }
        t.change(.filter) {}
        #expect(t.log == [.splitOpen, .splitOpen, .filter] && !t.animates)

        tab.closeSplit(closeActive: true)
        try await settle(0.6)
        #expect(tab.secondary == nil && tab.primary.list.layoutWidthOverride == nil)
    }
}
