import AppKit
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Offscreen layout and theme contracts. These tests never order, activate or make a window key.
@MainActor @Suite(.serialized, .isolatedSettings) struct ActivityAppearanceTests {
    @Test func compactTransferSectionsFollowAppearanceWithoutPresentingAWindow() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        // Other suites create real shared jobs concurrently. This empty-layout contract owns its data sources.
        let operations = FileOperationsController(), cloudEditing = CloudEditing()
        cloudEditing.operations = operations
        let controller = ActivityWindowController(controller: operations, cloudEditing: cloudEditing)
        let window = try #require(controller.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        #expect(window.title == "Transfers")
        #expect(!window.isVisible)
        content.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width == 480)
        #expect(window.contentLayoutRect.height < 300)
        #expect(operations.activities.isEmpty && cloudEditing.entries.isEmpty)
        #expect(descendants(content, as: TransferProgressView.self).isEmpty)
        #expect(descendants(content, as: CustomToolActivityView.self).isEmpty)
        #expect(descendants(content, as: NSTableView.self).isEmpty)
        #expect(descendants(content, as: NSPopUpButton.self).isEmpty)
        #expect(controller.emptyState.state == ActivityWindowController.emptyListState)
        for appearance in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = appearance; app.appearance = Theme.appearance; Theme.lookChanged()
            try #require(await eventually { window.effectiveAppearance.isDark == (appearance == .dark) })
            content.layoutSubtreeIfNeeded()
            #expect(!window.isVisible)
            if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
                try captureOffscreen(window, to: URL(fileURLWithPath: folder).appendingPathComponent("transfers-empty-\(appearance.rawValue).png"))
            }
        }
    }

    @Test func onlyLiveJobsAndActionableFailuresRemainWithoutClearingBackendHistory() throws {
        _ = NSApplication.shared
        let operations = FileOperationsController(), cloudEditing = CloudEditing()
        let controller = ActivityWindowController(controller: operations, cloudEditing: cloudEditing)
        let window = try #require(controller.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        operations.activities = [activity]
        for state: Activity.State in [.queued, .running, .paused, .waiting, .verifying, .failed, .interrupted] {
            activity.state = state
            controller.reload()
            #expect(descendants(content, as: TransferProgressView.self).count == 1)
            #expect(!window.isVisible && !window.isKeyWindow)
        }
        for state: Activity.State in [.completed, .cancelled] {
            activity.state = state
            controller.reload()
            #expect(descendants(content, as: TransferProgressView.self).isEmpty)
            #expect(operations.activities.first === activity)
            #expect(!window.isVisible && !window.isKeyWindow)
        }
        activity.state = .completed; activity.errors = ["Could not copy one item"]
        controller.reload()
        let card = try #require(descendants(content, as: TransferProgressView.self).first)
        let dismiss = try #require(descendants(card, as: NSButton.self).first { $0.title == "Dismiss" })
        dismiss.performClick(nil)
        #expect(descendants(content, as: TransferProgressView.self).isEmpty)
        #expect(operations.activities.first === activity)
        #expect(activity.errors == ["Could not copy one item"])
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func explicitlyOpenedProgressHidesAfterSuccessButKeepsFailuresActionable() throws {
        _ = NSApplication.shared
        let operations = FileOperationsController(), cloudEditing = CloudEditing()
        let window = RecordingTransferWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = ActivityWindowController(controller: operations, cloudEditing: cloudEditing, progressWindow: window)
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running; operations.activities = [activity]
        controller.show()
        #expect(window.presentations == 1)
        let hides = window.hides
        activity.state = .failed; activity.errors = ["Read failed"]
        controller.reload()
        #expect(window.hides == hides)
        #expect(descendants(try #require(window.contentView), as: TransferProgressView.self).count == 1)
        activity.state = .completed; activity.errors = []
        controller.reload()
        #expect(window.hides == hides + 1)
        // The test double records presentation requests but never orders a native window.
        #expect(!window.isVisible && !window.isKeyWindow)
        controller.show()
        #expect(window.presentations == 1)
    }

    @Test func concurrentOperationsKeepSeparateBoundedCardsAndScrollWithoutPresenting() throws {
        _ = NSApplication.shared
        let operations = FileOperationsController(), cloudEditing = CloudEditing()
        let controller = ActivityWindowController(controller: operations, cloudEditing: cloudEditing)
        let window = try #require(controller.window); defer { window.close() }
        let content = try #require(window.contentView)
        operations.activities = [Activity.State.running, .paused, .waiting, .queued].map { state in
            let activity = Activity(kind: .copy, sources: [URL(fileURLWithPath: "/fixture/Source")], destination: nil, job: nil)
            activity.state = state
            return activity
        }
        controller.reload(); content.layoutSubtreeIfNeeded()
        let cards = descendants(content, as: TransferProgressView.self)
        #expect(cards.count == 4)
        #expect(window.contentLayoutRect.height == 520)
        let scroll = try #require(descendants(content, as: NSScrollView.self).first)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        let frames = cards.map { $0.convert($0.bounds, to: document) }.sorted { $0.minY < $1.minY }
        for (previous, next) in zip(frames, frames.dropFirst()) { #expect(previous.maxY + 20 <= next.minY) }
        #expect(cards.allSatisfy { $0.bounds.width >= 400 && $0.bounds.width <= 600 })
        if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
            let previous = NSApp.appearance; defer { NSApp.appearance = previous; Theme.lookChanged() }
            for look in [AppearanceChoice.light, .dark] {
                Settings.shared.appearance = look; NSApp.appearance = Theme.appearance; window.appearance = Theme.appearance; Theme.lookChanged()
                content.layoutSubtreeIfNeeded()
                try captureOffscreen(window, to: URL(fileURLWithPath: folder).appendingPathComponent("transfers-concurrent-\(look.rawValue).png"))
            }
        }
        if let last = cards.max(by: { $0.convert($0.bounds, to: document).maxY < $1.convert($1.bounds, to: document).maxY }) {
            last.scrollToVisible(last.bounds)
            #expect(scroll.contentView.bounds.origin.y > 0, "The final queued operation remains reachable below the compact viewport")
        }
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

    private func captureOffscreen(_ window: NSWindow, to url: URL) throws {
        let content = try #require(window.contentView)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            // Caching a plain content view omits NSWindow's background; paint it only in this offscreen fixture.
            content.wantsLayer = true; content.layer?.backgroundColor = Theme.windowBackground.cgColor
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Exercises the actual show/finish call path without ever ordering or activating a native window.
@MainActor private final class RecordingTransferWindow: NSWindow {
    var presentations = 0
    var hides = 0
    override func orderFront(_ sender: Any?) { presentations += 1 }
    override func orderOut(_ sender: Any?) { hides += 1 }
}
