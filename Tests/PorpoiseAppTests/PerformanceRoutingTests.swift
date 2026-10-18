import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct PerformanceRoutingTests {
    init() { _ = NSApplication.shared }
    @Test func compactResizeAndSavedZoomReuseMeasurementsUntilContentChanges() throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let items = (0..<50_100).map {
            FileItem(url: scratch.url.appendingPathComponent("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        model.searchResults = items
        model.props.mode = .compact
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        scroll.documentView = view
        model.onChange = { [weak view] in view?.relayout() }
        view.computeLayout()
        let count = view.textMeasurementCount
        for size: CGFloat in [64, 65, 80] {
            scroll.frame.size.width += 1
            view.transitions.resized()
            view.previewZoom(size, commitAfter: nil)
            view.commitZoom()
        }
        #expect(view.textMeasurementCount == count)
        let oldWidth = view.frames[0].width
        model.searchResults = [items[0].named(String(repeating: "wide ", count: 30))] + items.dropFirst()
        #expect(view.textMeasurementCount > count)
        #expect(view.frames[0].width > oldWidth)
        model.filter = NameFilter(text: "no-such-name")
        #expect(view.frames.isEmpty)
    }

    @Test func textSettingsStillInvalidateCompactLabels() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = [FileItem(url: scratch.url.appendingPathComponent("name.txt"), name: "name.txt", isDirectory: false)]
        model.props.mode = .compact
        let view = ItemListView(model: model)
        view.computeLayout()
        let before = view.textMeasurementCount
        Settings.shared.labelFontSize += 3
        #expect(view.textMeasurementCount > before)
        let fontCount = view.textMeasurementCount
        Settings.shared.showAllExtensions = false
        #expect(view.textMeasurementCount > fontCount)
        let width = view.frames[0].width
        Settings.shared.permissionStyle = .combined
        model.props.setRoles([.permissions], for: .compact)
        view.computeLayout()
        #expect(view.frames[0].width >= width)
    }

    @Test func unrelatedPreferencesDoNotRebuildVisibleOrHiddenPanes() throws {
        let scratch = try Scratch()
        let panes = [ViewContainer(url: scratch.url), ViewContainer(url: scratch.url)]
        panes[1].isHidden = true
        var rebuilds = 0
        for pane in panes { pane.model.onChange = { rebuilds += 1 } }
        Settings.shared.terminalFollowsDirectory.toggle()
        Settings.shared.confirmDelete.toggle()
        Settings.shared.appLibraryIconSize += 1
        #expect(rebuilds == 0)
        Settings.shared.hideBackupFiles.toggle()
        #expect(rebuilds == panes.count)
        Settings.shared.resetAll()
        #expect(rebuilds > panes.count)
    }

    @Test func tagMenuReadsOffMainAndStopsAtEmptyIntersection() async throws {
        let scratch = try Scratch()
        let reads = Reads()
        let view = TagDotsView.view(
            for: (0..<100_000).map { scratch.url.appendingPathComponent("\($0)") },
            read: { _ in
                reads.record()
                return []
            }
        ) { _ in }
        #expect(view.isLoading)
        await expectEventually { !view.isLoading }
        #expect(reads.count == 1 && !reads.usedMain)
        #expect(view.current.isEmpty)
    }

    @Test func asynchronousTagsPreserveTheCommonTagChecks() async throws {
        let scratch = try Scratch()
        let reads = Reads()
        let view = TagDotsView.view(
            for: [scratch.url.appendingPathComponent("a"), scratch.url.appendingPathComponent("b")],
            read: { url in
                reads.record()
                return FinderTags.standard.filter { url.lastPathComponent == "a" ? ["Red", "Blue"].contains($0.name) : $0.name == "Blue" }
            }
        ) { _ in }
        await expectEventually { !view.isLoading }
        #expect(view.current == ["Blue"])
        #expect(reads.count == 2 && !reads.usedMain)
    }

    @Test func propertiesUsesKnownItemsAndCompletesAfterConstruction() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let item = FileItem(url: scratch.url.appendingPathComponent("virtual.txt"), name: "virtual.txt", isDirectory: false, size: 123)
        let controller = PropertiesWindow(urls: [item.url], items: [item])
        #expect(controller.localItems.isEmpty)
        await expectEventually { !controller.localItems.isEmpty }
        #expect(controller.localItems == [item])
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let content = try #require(controller.window?.contentView)
        let locked = try #require(buttons(content).first { $0.title == "Locked" })
        #expect(locked.image is ChoiceImage)
        controller.window?.close()
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var main = false
        var count: Int { lock.withLock { value } }
        var usedMain: Bool { lock.withLock { main } }
        func record() {
            lock.withLock {
                value += 1; main = main || Thread.isMainThread
            }
        }
    }
}
