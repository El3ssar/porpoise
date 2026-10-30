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
        let host: NSView
        let panel: InformationPanel
        if inColumn {
            let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            column.show(file, container: pane)
            host = column; panel = column.information
        } else {
            panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            panel.show(hovered: nil, container: pane)
            host = panel
        }
        defer { withExtendedLifetime(host) {} }
        let preview = try #require(panel.subviews.compactMap { $0 as? PreviewImageView }.first)
        #expect(preview.image === small)

        try #require(await poll { thumbnails.thumbnail(for: item, size: 256, exact: true) != nil })
        let large = try #require(thumbnails.thumbnail(for: item, size: 256, exact: true))
        let smallPixels = small.representations.map(\.pixelsWide).max() ?? 0
        let largePixels = large.representations.map(\.pixelsWide).max() ?? 0
        #expect(largePixels > smallPixels)
        #expect(preview.image === large)
    }
}
