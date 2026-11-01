import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Offscreen layout and theme contracts. These tests never order, activate or make a window key.
@MainActor @Suite(.serialized, .isolatedSettings) struct ActivityAppearanceTests {
    @Test func compactTransferSectionsFollowAppearanceWithoutPresentingAWindow() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let controller = ActivityWindowController.shared
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let tools = try #require(descendants(content, as: CustomToolActivityView.self).first)
        let navigation = try #require(descendants(content, as: NSPopUpButton.self).first { $0.itemTitles == ["Transfers", "History", "Tools"] })
        #expect(window.title == "Transfers")
        #expect(!window.isVisible)
        content.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width == 480)
        #expect(window.contentLayoutRect.height < 300)
        #expect(descendants(content, as: NSSegmentedControl.self).isEmpty)
        let empty = controller.emptyState
        #expect(empty.state == nil || empty.state == ActivityWindowController.emptyListState)
        empty.show(nil); empty.show(ActivityWindowController.emptyListState)
        let labels = descendants(empty, as: NSTextField.self).filter { !$0.isHidden && !$0.stringValue.isEmpty }
        let title = try #require(labels.first { $0.stringValue == "No activity" })
        let message = try #require(labels.first { $0.stringValue == "Copies and moves show up here." })
        #expect((message.font?.pointSize ?? 99) < (title.font?.pointSize ?? 0))
        #expect(message.textColor == title.textColor)
        for appearance in [AppearanceChoice.light, .dark, .light] {
            Settings.shared.appearance = appearance; app.appearance = Theme.appearance; Theme.lookChanged()
            try #require(await eventually { window.effectiveAppearance.isDark == (appearance == .dark) })
            for section in 0..<navigation.numberOfItems {
                navigation.selectItem(at: section)
                navigation.sendAction(navigation.action, to: navigation.target)
                content.layoutSubtreeIfNeeded()
                #expect(!window.isVisible)
                #expect(navigation.convert(navigation.bounds, to: content).minX >= 0)
                #expect(navigation.frame.width >= navigation.intrinsicContentSize.width)
                if section == 2 {
                    #expect(!tools.isHidden)
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        #expect(tools.table.backgroundColor.usingColorSpace(.sRGB) == Theme.viewBackground.usingColorSpace(.sRGB))
                        #expect(tools.output.textColor?.usingColorSpace(.sRGB) == Theme.viewText.usingColorSpace(.sRGB))
                    }
                }
                if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
                    try captureOffscreen(
                        window, to: URL(fileURLWithPath: folder).appendingPathComponent("transfers-\(section)-\(appearance.rawValue).png"))
                }
            }
        }
        navigation.selectItem(at: 0); navigation.sendAction(navigation.action, to: navigation.target)
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

    private func captureOffscreen(_ window: NSWindow, to url: URL) throws {
        let content = try #require(window.contentView)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
