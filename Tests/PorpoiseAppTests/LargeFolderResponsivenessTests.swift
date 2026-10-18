import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Big folders on the main thread: folder previews list on a worker queue, and the Apps grid's tiles fit a byte budget.
/// (The Folders panel's local listing is tested with the panel's other tests.)
@Suite(.serialized) struct LargeFolderResponsivenessTests {
    @Test func firstNamesKeepFinderOrderWithoutSortingEverything() throws {
        let scratch = try Scratch(), fm = FileManager.default
        let names = (0..<500).map { "Item \($0 * 7919 % 1000)" } + ["item 10", "Item 9", "ÉTÉ", "ete", ".hidden"]
        for n in names { fm.createFile(atPath: scratch.url.appendingPathComponent(n).path, contents: nil) }
        // As the disk spells them: on a case-insensitive volume "item 10" and "Item 10" are one file.
        let listed = try fm.contentsOfDirectory(atPath: scratch.url.path)
        let expected = listed.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for count in [1, 80, 1000] {
            #expect(Thumbnails.firstNames(in: scratch.url, count: count) == Array(expected.prefix(count)))
        }
    }

    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func folderPreviewNeverListsWhileDrawing() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch(), fm = FileManager.default
        let folderURL = scratch.url.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for i in 0..<2000 { fm.createFile(atPath: folderURL.appendingPathComponent("note-\(i).txt").path, contents: nil) }
        Settings.shared.previewFolders = true
        Settings.shared.previewText = false
        let folder = try #require(FileItem.load(folderURL))
        let thumbnails = Thumbnails()
        var ready = 0
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { n in
            if n.object as? URL == folderURL { MainActor.assumeIsolated { ready += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // The first ask (and asks while listing) start one listing and draw the plain folder.
        #expect(thumbnails.folderPreview(for: folder, size: 64) == nil)
        #expect(thumbnails.folderPreview(for: folder, size: 128) == nil)
        await expectEventually { ready == 1 }
        // Listed: no file wants a preview (text previews are off), so the folder keeps its plain icon.
        #expect(thumbnails.folderPreview(for: folder, size: 64) == nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ready == 1)
        // A settings change forgets the listing: the next ask lists again.
        thumbnails.resetFolderPreviews()
        #expect(thumbnails.folderPreview(for: folder, size: 64) == nil)
        await expectEventually { ready == 2 }
    }

    @Test(.isolatedSettings, .timeLimit(.minutes(2))) @MainActor func appsGridTilesStayWithinTheirByteBudget() throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let apps = (0..<160).map { i in
            FileItem(url: URL(fileURLWithPath: "/Applications/Fixture-\(i).app"), name: "Fixture-\(i).app", isDirectory: true, isApplication: true)
        }
        model.searchResults = apps
        let grid = AppsGridView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1400, height: 900))
        scroll.documentView = grid
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        func draw(_ y: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            grid.draw(CGRect(x: 0, y: y, width: 1400, height: 900))
            NSGraphicsContext.restoreGraphicsState()
        }
        // 160 apps at 256 pt are 250 MB of tiles, and the sizes before stay as stand-ins: scrolled through, the grid
        // keeps what's on screen and stays near its budget.
        var peak = 0
        for size in [256.0, 224, 192] as [CGFloat] {
            grid.previewZoom(size, commitAfter: nil)
            grid.commitZoom()
            var y: CGFloat = 0
            while y < grid.bounds.height {
                for _ in 0..<30 { draw(y) }
                peak = max(peak, grid.retainedTileBytes)
                y += 900
            }
        }
        // One screen of the largest size may go over (it is on screen), never the whole library.
        #expect(peak <= AppsGridView.tileBudget + 40 << 20)
        #expect(grid.retainedTileBytes > 0)
        // Apps no longer listed are forgotten.
        model.searchResults = Array(apps.prefix(1))
        grid.updateLayout(width: 1400)
        #expect(grid.retainedTileBytes <= 3 * 1_638_400)
    }
}
