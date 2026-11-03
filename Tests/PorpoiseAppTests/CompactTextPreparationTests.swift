import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.isolatedSettings) struct CompactTextPreparationTests {
    init() { _ = NSApplication.shared }

    @Test func batchedWidthsMatchIndividualNativeLayout() throws {
        let labels = [
            "", "   ", " leading", "trailing  ", "AVATAR", "ToWa", "office-ffi.txt", "file-99999.txt",
            "a\nb", "a\r\nb", "a\rb", "a\tb", "a\u{2028}b", "a\u{2029}b", "\u{202e}abc", "\u{2066}abc",
            "é", "e\u{301}", "\u{301}", "東京", "مرحبا", "👨‍👩‍👧‍👦", "\u{200d}🙂", String(repeating: "W", count: 3000),
        ]
        let fonts = [NSFont.systemFont(ofSize: 13), try #require(NSFont(name: "Times New Roman", size: 17))]
        for font in fonts {
            for first in labels {
                for second in labels {
                    let pair = [first, second]
                    let expected = pair.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                    #expect(CompactTextPreparation.widest(pair, font: font) == expected)
                }
            }
            // Longer batches must retain shaping; very large Core Text inputs may skip kerning.
            let many = (0..<3000).map { "file-\($0).txt" }
            let expected = many.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            #expect(CompactTextPreparation.widest(many, font: font) == expected)
        }
    }

    @Test func largeCompactPublishesExactGeometryAfterYieldingAndRestoresScroll() async throws {
        let (model, view, scroll) = try fixture()
        let selected = model.rows[2500].item.url
        model.currentURL = selected
        view.computeLayout()
        #expect(view.isPreparingCompact)
        #expect(view.frames.isEmpty)
        #expect(view.accessibilityValue() as? String == "Loading Compact view")
        try captureLoading(view, scroll: scroll)
        view.scroll(CGPoint(x: 600, y: 0))
        #expect(view.compactPendingScroll == CGPoint(x: 600, y: 0))
        // Type-ahead/selection remains meaningful while exact geometry is preparing.
        view.scrollToItem(2500)
        #expect(view.compactPendingScrollItem == selected)
        var mainTurnRan = false
        DispatchQueue.main.async { mainTurnRan = true }
        await expectEventually { mainTurnRan }
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        let expected = model.rows.map { view.textWidth(model.displayName(for: $0.item)) }.max() ?? 0
        #expect(view.compactTextMeasurement?.width == expected)
        #expect(view.compactTextMeasurement?.complete == true)
        #expect(view.compactPendingScroll == nil && view.compactPendingScrollItem == nil)
        #expect(scroll.contentView.bounds.intersects(view.frames[2500]))
        #expect(model.currentURL == selected)
        #expect(view.accessibilityValue() == nil)
        let measurements = view.textMeasurementCount
        let oldWidth = view.frames[0].width
        view.computeLayout()
        #expect(!view.isPreparingCompact && view.frames[0].width == oldWidth)
        #expect(view.textMeasurementCount == measurements)
        #expect(view.window == nil)
    }

    @Test func obsoleteResultsCannotReplaceNewRowsOrAnotherMode() async throws {
        let (model, view, _) = try fixture()
        view.computeLayout()
        let obsolete = try #require(view.compactTextPreparation)
        model.searchResults = [FileItem(url: model.location.appendingPathComponent("replacement"), name: "replacement", isDirectory: false)]
        view.computeLayout()
        #expect(!view.isPreparingCompact && view.frames.count == 1)
        let replacement = view.compactTextMeasurement?.width
        // A main-queue barrier after the worker's queued batch observes its delivery.
        await withCheckedContinuation { continuation in
            CompactTextPreparation.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(view.compactTextPreparation !== obsolete)
        #expect(view.compactTextMeasurement?.width == replacement)
        #expect(view.frames.count == 1)

        model.searchResults = (0..<3000).map { FileItem(url: model.location.appendingPathComponent("\($0)"), name: "\($0)", isDirectory: false) }
        view.computeLayout()
        #expect(view.isPreparingCompact)
        model.props.mode = .details
        view.computeLayout()
        await withCheckedContinuation { continuation in
            CompactTextPreparation.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(!view.isPreparingCompact && view.frames.count == 3000)
        #expect(view.frames.rowsPerColumn == nil)
    }

    @Test func settingsAndZoomRestartOnlyTheObsoleteRequest() async throws {
        let (model, view, _) = try fixture()
        view.computeLayout()
        let first = try #require(view.compactTextPreparation)
        Settings.shared.showAllExtensions.toggle()
        view.computeLayout()
        let second = try #require(view.compactTextPreparation)
        #expect(first !== second)
        model.props.setRoles([.size], for: .compact)
        view.computeLayout()
        let third = try #require(view.compactTextPreparation)
        #expect(second !== third && third.roles == [.size])
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        let expected =
            model.rows.flatMap { [model.displayName(for: $0.item), model.text(for: .size, of: $0.item)] }
            .map { view.textWidth($0) }.max() ?? 0
        #expect(view.compactTextMeasurement?.width == expected)
    }

    @Test func arrowKeysUseTheFinalColumnTopologyWhilePreparing() async throws {
        let (model, view, _) = try fixture()
        model.searchResults = (0..<3000).map {
            let name = ["Alpha", "Beta", "Gamma"][$0 / 1000] + "-\($0).txt"
            return FileItem(url: model.location.appendingPathComponent(name), name: name, isDirectory: false)
        }
        model.props.groupRole = .name
        view.computeLayout()
        #expect(view.isPreparingCompact)
        var moves: [(Int, UInt16, URL?)] = []
        for index in [0, 100, 999, 1000, 2999] {
            for key: UInt16 in [123, 124, 125, 126, 115, 119, 116, 121] {
                model.currentURL = model.rows[index].item.url
                view.keyDown(with: event(key))
                moves.append((index, key, model.currentURL))
            }
        }
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        for (index, key, expected) in moves {
            model.currentURL = model.rows[index].item.url
            view.keyDown(with: event(key))
            #expect(model.currentURL == expected)
        }
    }

    @Test func asyncZoomKeepsTheCurrentItemsViewportOffset() async throws {
        let (model, view, scroll) = try fixture()
        model.searchResults = (0..<3000).map {
            let name = "project-\($0)-short-file-name.txt"
            return FileItem(url: model.location.appendingPathComponent(name), name: name, isDirectory: false)
        }
        Settings.shared.compactMaxWidth = 0
        view.previewZoom(16, commitAfter: nil)
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        #expect(view.compactTextMeasurement?.complete == false)
        model.currentURL = model.rows[2500].item.url
        view.scroll(CGPoint(x: view.frames[2500].minX - 20, y: 0))
        let offset = view.frames[2500].minX - view.visibleRect.minX
        view.previewZoom(128, commitAfter: nil)
        #expect(view.isPreparingCompact)
        let firstAnchor = view.compactPendingAnchor
        view.previewZoom(256, commitAfter: nil)
        #expect(view.isPreparingCompact)
        #expect(view.compactPendingAnchor?.url == firstAnchor?.url)
        #expect(view.compactPendingAnchor?.offset == firstAnchor?.offset)
        view.commitZoom()
        #expect(view.compactPendingAnchor?.offset == firstAnchor?.offset)
        #expect(view.compactPendingAnchor?.url == model.currentURL)
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        #expect(abs(view.frames[2500].minX - view.visibleRect.minX - offset) < 1)
        #expect(scroll.documentView === view)
    }

    @Test func metadataArrivingDuringThePassDoesNotRestartItsPrefix() async throws {
        let (model, view, _) = try fixture()
        model.props.setRoles([.tags], for: .compact)
        model.onMetadataLoaded = {
            view.invalidateCompactMetadata()
            view.relayout()
        }
        view.computeLayout()
        let first = try #require(view.compactTextPreparation)
        view.invalidateCompactMetadata()
        view.computeLayout()
        #expect(view.compactTextPreparation === first)
        #expect(view.compactMetadataChangedWhilePreparing)
        await expectEventually { !view.isPreparingCompact && view.frames.count == model.rows.count }
        let measured = view.textMeasurementCount
        await withCheckedContinuation { continuation in
            CompactTextPreparation.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(view.compactTextMeasurement?.complete == true)
        #expect(view.textMeasurementCount == measured)
        #expect(view.window == nil)
        model.onMetadataLoaded = nil
    }

    private func captureLoading(_ view: ItemListView, scroll: NSScrollView) throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_COMPACT_CAPTURES"] else { return }
        let root = NSView(frame: scroll.frame)
        root.addSubview(scroll)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for choice in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = choice
            NSApplication.shared.appearance = Theme.appearance
            Theme.lookChanged()
            window.appearance = Theme.appearance
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("compact-loading-\(choice.rawValue).png"))
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    private func event(_ key: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
    }

    private func fixture() throws -> (DirectoryModel, ItemListView, NSScrollView) {
        let scratch = try Scratch("compact-preparation")
        Settings.shared.compactMaxWidth = 1000
        Settings.shared.folderSizeMode = .none
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<3000).map {
            FileItem(url: scratch.url.appendingPathComponent("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        model.props.mode = .compact
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        scroll.documentView = view
        return (model, view, scroll)
    }
}
