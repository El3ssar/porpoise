import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Exercise the app-level appearance change: setting a window's appearance alone skips followLook's refresh.
@MainActor @Suite(.serialized, .isolatedSettings) struct ActivityAppearanceTests {
    @Test func activityTabsFollowLightAndDarkAppearance() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let controller = ActivityWindowController.shared
        let window = try #require(controller.window)
        defer { window.close() }
        let content = try #require(window.contentView)
        let tools = try #require(descendants(content, as: CustomToolActivityView.self).first)
        let originalSize = window.contentLayoutRect.size
        defer { window.setContentSize(originalSize) }
        let tabs = try #require(descendants(content, as: NSSegmentedControl.self).first)
        let buttons = descendants(tools, as: NSButton.self)
        #expect(buttons.map(\.title) == ["Cancel Tool", "Clear Finished"])
        for width in [480.0, 640.0] {
            window.setContentSize(NSSize(width: width, height: 460))
            content.layoutSubtreeIfNeeded()
            #expect(tabs.frame.width >= tabs.intrinsicContentSize.width)
            #expect(tabs.convert(tabs.bounds, to: content).minX >= 88)
        }
        for look in [AppearanceChoice.light, .dark, .light] {
            Settings.shared.appearance = look
            app.appearance = Theme.appearance
            try #require(await eventually { window.effectiveAppearance.isDark == (look == .dark) })
            Theme.lookChanged()
            #expect(window.effectiveAppearance.isDark == (look == .dark))
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                #expect(window.backgroundColor.usingColorSpace(.sRGB) == Theme.windowBackground.usingColorSpace(.sRGB))
                #expect(tools.table.backgroundColor.usingColorSpace(.sRGB) == Theme.viewBackground.usingColorSpace(.sRGB))
                #expect(tools.output.backgroundColor.usingColorSpace(.sRGB) == Theme.viewBackground.usingColorSpace(.sRGB))
                #expect(tools.output.textColor?.usingColorSpace(.sRGB) == Theme.viewText.usingColorSpace(.sRGB))
            }
            for segment in 0..<tabs.segmentCount {
                tabs.selectedSegment = segment
                tabs.sendAction(tabs.action, to: tabs.target)
                content.layoutSubtreeIfNeeded()
                if segment == 2 {
                    for button in buttons {
                        #expect(button.frame.width >= button.intrinsicContentSize.width)
                        #expect(button.frame.height > 16 && !button.isHiddenOrHasHiddenAncestor)
                        #expect(button.effectiveAppearance.isDark == (look == .dark))
                        #expect(button.cell?.title == button.title)
                    }
                }
                if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
                    try await capture(window, to: URL(fileURLWithPath: folder).appendingPathComponent("activity-\(segment)-\(look.rawValue).png"))
                }
            }
        }
    }

    private func descendants<T: NSView>(_ view: NSView, as kind: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: kind) }
    }

    private func capture(_ window: NSWindow, to url: URL) async throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        // Native button/segmented-control layers are not included faithfully by cacheDisplay on macOS 27.
        // Capture only this test window through WindowServer as well; ordering it does not activate the app.
        window.orderFront(nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = try #require(WindowCapture.image(of: window.windowNumber))
        let server = url.deletingPathExtension().appendingPathExtension("window.png")
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: server)
    }
}
