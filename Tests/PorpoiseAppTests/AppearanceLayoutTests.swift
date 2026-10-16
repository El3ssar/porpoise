import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

@Suite(.serialized) struct AppearanceLayoutTests {
    @Test @MainActor func closingAuxiliaryWindowDoesNotQuitAnOrderedOutBrowser() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "app.porpoise.lifetime-test.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        let previousStore = Settings.store
        let previousTesting = Settings.isTesting
        Settings.store = store
        Settings.isTesting = true
        defer {
            Settings.store = previousStore
            Settings.isTesting = previousTesting
            store.removePersistentDomain(forName: suite)
        }
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
                #expect(abs(button.frame.width - buttons[0].frame.width) < 1)
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

extension AppearanceLayoutTests {
    @Test @MainActor func compareZoomResetKeepsBothNativeRowsAlignedAtTheDefault() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let suite = "app.porpoise.compare-zoom-test.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        let previousStore = Settings.store, previousTesting = Settings.isTesting
        Settings.store = store; Settings.isTesting = true
        defer {
            Settings.store = previousStore; Settings.isTesting = previousTesting
            store.removePersistentDomain(forName: suite)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let left = folder.appendingPathComponent("A"), right = folder.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = MainWindowController(urls: [left], split: [right])
        defer { controller.tab.installComparison(nil); controller.window?.close() }
        for container in controller.tab.containers {
            var props = container.model.props; props.mode = .details; props.setIconSize(48, for: .details); container.model.props = props
        }
        let comparison = CompareView(model: CompareModel(left: left, right: right))
        controller.tab.installComparison(comparison)
        #expect(controller.tab.containers.allSatisfy { $0.list.iconSize == 48 })
        controller.zoomReset(nil)
        var defaults = controller.view.model.props; defaults.resetIconSize(for: .details)
        let expected = defaults.iconSize(for: .details)
        #expect(expected < 48)
        #expect(controller.tab.containers.allSatisfy { $0.list.iconSize == expected })
        #expect(controller.tab.containers.allSatisfy { $0.list.comparisonRowHeight == comparison.document.rowHeight })
        #expect(comparison.document.rowHeight >= expected + 2 * ItemListView.pad + 2)
    }
}
