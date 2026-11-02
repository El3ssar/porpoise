import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct InformationThumbnailTests {
    @Test(arguments: [false, true])
    func cachedImagesUpdateWhenLargerThumbnailsAreReady(inColumn: Bool) async throws {
        _ = NSApplication.shared
        Settings.shared.infoShowPreview = true
        Settings.shared.previewImages = true
        Settings.shared.infoShowHovered = false
        let scratch = try Scratch()
        let file = scratch.path("striped.png")
        let image = NSImage(size: NSSize(width: 1024, height: 768), flipped: false) { bounds in
            NSColor.blue.setFill(); bounds.fill()
            NSColor.white.setFill()
            for x in stride(from: 0, to: 1024, by: 16) {
                NSRect(x: x, y: 0, width: 4, height: 768).fill()
            }
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let item = try #require(FileItem.load(file))
        let pane = ViewContainer(url: scratch.url)
        try #require(await poll { pane.model.rows.count == 1 })
        pane.list.select(file)

        // Put a small thumbnail in the cache before the panel opens.
        let thumbnails = Thumbnails.shared
        try #require(await poll { thumbnails.thumbnail(for: item, size: 32, exact: true) != nil })
        let small = try #require(thumbnails.thumbnail(for: item, size: 32, exact: true))
        // An unattached panel deliberately forgets its presentation on the next main-queue turn.
        // Give the fixture a real window lifecycle without showing or activating any window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host: NSView
        let panel: InformationPanel
        if inColumn {
            let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            // A layout rebuild can queue nil-window cleanup just before a newer presentation.
            column.information.viewDidMoveToWindow()
            window.contentView = column
            column.show(file, container: pane)
            host = column; panel = column.information
        } else {
            panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            panel.viewDidMoveToWindow()
            window.contentView = panel
            panel.show(hovered: nil, container: pane)
            host = panel
        }
        defer { withExtendedLifetime((host, pane, window)) {} }
        #expect(panel.window === window && !window.isVisible && !window.isKeyWindow)
        let preview = try #require(panel.subviews.compactMap { $0 as? PreviewImageView }.first)
        #expect(preview.image === small)

        let producerThreads = Locked<[Bool]>([])
        var mainDeliveries = 0
        var expectedLarge: NSImage?
        func pixels(_ image: NSImage?) -> Int { image?.representations.map(\.pixelsWide).max() ?? 0 }
        func snapshot(_ phase: String) -> String {
            let fields = Array(Mirror(reflecting: panel).children)
            let shown = fields.first { $0.label == "shownURLs" }?.value as? [URL]
            let observer = fields.first { $0.label == "thumbnailObserver" }.map { String(reflecting: $0.value) } ?? "missing"
            let cache = Mirror(reflecting: thumbnails).children.first { $0.label == "cache" }?.value as? NSCache<NSString, NSImage>
            let key = "\(item.url.path)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|256" as NSString
            let cached = cache?.object(forKey: key)
            let stamp = fields.first { $0.label == "shownStamp" }.map { String(reflecting: $0.value) } ?? "missing"
            let selected = pane.model.selectedItems.map { "\($0.url.path):\($0.modificationDate?.timeIntervalSince1970 ?? 0)" }
            return "\(phase): shown=\(String(describing: shown)), observer=\(observer), selected=\(selected), "
                + "attached=\(panel.window === window), visible=\(window.isVisible), key=\(window.isKeyWindow), "
                + "previewPixels=\(pixels(preview.image)), cachePixels=\(pixels(cached)), stamp=\(stamp), directDate=\(String(describing: item.modificationDate)), "
                + "smallIdentity=\(preview.image === small), largeIdentity=\(preview.image === expectedLarge), cacheLargeIdentity=\(cached === expectedLarge), "
                + "producerThreads=\(producerThreads.value), mainDeliveries=\(mainDeliveries), loading=\(pane.model.isLoading), "
                + "settings=(preview:\(Settings.shared.infoShowPreview), images:\(Settings.shared.previewImages), maxMiB:\(Settings.shared.previewMaxSizeMiB))"
        }
        var deliveries = [snapshot("subscribed")]
        let producerObserver = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: nil) { @Sendable n in
            guard (n.object as? URL) == file else { return }
            producerThreads.append(Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(producerObserver) }
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard (n.object as? URL) == file else { return }
                mainDeliveries += 1
                deliveries.append(snapshot("ready"))
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try #require(await poll { thumbnails.thumbnail(for: item, size: 256, exact: true) != nil })
        let large = try #require(thumbnails.thumbnail(for: item, size: 256, exact: true))
        expectedLarge = large
        let smallPixels = small.representations.map(\.pixelsWide).max() ?? 0
        let largePixels = large.representations.map(\.pixelsWide).max() ?? 0
        #expect(largePixels > smallPixels)
        // Cache availability is not the panel's completion signal, and NSCache may replace that image.
        // Verify the visible result: the preview must reach the larger resolution after notification delivery.
        let updated = await poll { pixels(preview.image) >= largePixels }
        if !updated {
            let diagnostic =
                (["Information thumbnail inColumn=\(inColumn), targetPixels=\(largePixels)"] + deliveries + [snapshot("failed")])
                .joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        #expect(updated)
        #expect(producerThreads.value.allSatisfy { $0 })
        #expect(panel.window === window)
        #expect(Settings.shared.infoShowPreview && Settings.shared.previewImages)
        #expect(pane.model.selectedItems.map(\.url) == [file])
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
