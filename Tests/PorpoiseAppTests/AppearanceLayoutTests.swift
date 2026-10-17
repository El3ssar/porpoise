import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

@Suite(.serialized) struct AppearanceLayoutTests {
    @Test @MainActor func dropboxTileOnlyOffersSignInWithAConfiguredKey() throws {
        for key in ["", "configured-key"] {
            let descriptor = try #require(CloudProviderDescriptor.catalog(dropbox: .init(appKey: key)).first { $0.provider == .dropbox })
            let tile = ConnectTile(title: descriptor.title, image: nil, available: descriptor.available)
            var pressed = false; tile.onClick = { pressed = true }
            #expect(tile.accessibilityLabel() == (key.isEmpty ? "Dropbox, coming soon" : "Dropbox"))
            #expect(tile.accessibilityPerformPress() == !key.isEmpty)
            #expect(pressed == !key.isEmpty)
        }
    }

    @Test(.isolatedSettings) @MainActor func closingAuxiliaryWindowDoesNotQuitAnOrderedOutBrowser() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "app.porpoise.lifetime-test.\(UUID().uuidString)"
        let delegate = AppDelegate.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        delegate.newWindow(at: folder)
        let browser = try #require(delegate.windows.last)
        defer { if delegate.windows.contains(where: { $0 === browser }) { browser.window?.close() } }
        browser.window?.orderOut(nil)
        let dragImage = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        dragImage.isReleasedWhenClosed = false
        dragImage.close()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        #expect(delegate.windows.contains { $0 === browser })
        browser.window?.close()
        #expect(delegate.windows.isEmpty)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app) == !app.isHidden)
    }

    @Test(arguments: [1, 2, 3, 4, 12]) @MainActor func themeCardsFillThreeColumnsAcrossResizeAndRefresh(count: Int) {
        _ = NSApplication.shared
        let form = FormBuilder()
        form.grouped = true
        form.section("Theme")
        let names = Array((["Follow system"] + AppearanceTheme.builtIns.map(\.name) + ["Custom"]).prefix(count))
        var selected = names[0]
        form.themeCards(names, selected: { selected }, theme: { _ in AppearanceTheme.builtIns[0] }) { selected = names[$0] }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = form.view
        defer { window.close() }
        func cards(_ view: NSView) -> [ThemePreviewButton] {
            (view as? ThemePreviewButton).map { [$0] } ?? view.subviews.flatMap(cards)
        }
        let buttons = cards(form.view)
        #expect(buttons.count == names.count)
        for width in [760.0, 640.0, 1000.0, 760.0] {
            window.setContentSize(NSSize(width: width, height: 580))
            form.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            for button in buttons {
                #expect(button.frame.width > 100)
                #expect(abs(button.frame.width - buttons[0].frame.width) <= 1)  // whole-pixel columns at 1x differ by up to 1 pt
                #expect(abs(button.frame.height - 62) < 1)
                #expect(!button.hasAmbiguousLayout)
            }
        }
        buttons.last?.performClick(nil)
        form.refresh()
        #expect(selected == names.last)
        #expect(buttons.last?.state == .on)
        if count > 1 { #expect(buttons.first?.state == .off) }
    }
}
