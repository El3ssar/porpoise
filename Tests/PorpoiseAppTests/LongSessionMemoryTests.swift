import AppKit
import Darwin
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Real AppKit attachment changes only: no window is ordered, activated or made key.
@MainActor @Suite(.serialized, .isolatedSettings) struct LongSessionMemoryTests {
    private final class WeakImage { weak var value: NSImage?; init(_ value: NSImage) { self.value = value } }

    private func mainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func preview(in panel: InformationPanel) throws -> PreviewImageView {
        try #require(panel.subviews.compactMap { $0 as? PreviewImageView }.first)
    }

    private func bitmap(side: Int) throws -> NSImage {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32))
        let bytes = try #require(rep.bitmapData)
        bytes.initialize(repeating: 127, count: rep.bytesPerRow * rep.pixelsHigh)
        let image = NSImage(size: NSSize(width: CGFloat(side), height: CGFloat(side)))
        image.addRepresentation(rep)
        return image
    }

    @Test func aParkedPreviewReleasesItsImageWhileTheTabRemainsAlive() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)), window = window()
        window.contentView = host
        let column = ColumnPreviewView(frame: host.bounds)
        host.addSubview(column)
        var image: NSImage? = try bitmap(side: 32)
        let reference = WeakImage(try #require(image))
        try preview(in: column.information).image = image
        image = nil
        #expect(reference.value != nil)
        column.removeFromSuperview()
        await mainTurn(); await mainTurn()
        #expect(reference.value == nil)
        #expect(column.information.window == nil && !window.isVisible && !window.isKeyWindow)
        withExtendedLifetime(column) {}
        window.contentView = nil; window.close()
    }

    @Test func clearingThePreviewColumnReleasesContentBeforeTheColumnIsRemoved() throws {
        let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        window.contentView = column
        let reference = try autoreleasepool { () throws -> WeakImage in
            let image = try bitmap(side: 32), reference = WeakImage(image)
            try preview(in: column.information).image = image
            column.clear()
            #expect(try preview(in: column.information).image == nil)
            return reference
        }
        // AppKit's setter may autorelease the old image; drain that pool before testing ownership.
        #expect(reference.value == nil)
        #expect(column.window === window && !window.isVisible && !window.isKeyWindow)
        window.contentView = nil; window.close()
    }

    @Test func closingTheWindowReleasesThePreviewEvenIfThePanelIsRetained() throws {
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        window.contentView = panel
        let reference = try autoreleasepool { () throws -> WeakImage in
            let image = try bitmap(side: 32), reference = WeakImage(image)
            try preview(in: panel).image = image
            window.close()
            #expect(try preview(in: panel).image == nil)
            return reference
        }
        #expect(reference.value == nil)
        #expect(!window.isVisible && !window.isKeyWindow)
        withExtendedLifetime(panel) {}
        window.contentView = nil
    }

    @Test func sameTurnReparentingPreservesTheCurrentPreview() async throws {
        let left = window(), right = window()
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        left.contentView = panel
        var image: NSImage? = try bitmap(side: 32)
        let reference = WeakImage(try #require(image))
        try preview(in: panel).image = image
        image = nil
        left.contentView = nil
        right.contentView = panel
        await mainTurn(); await mainTurn()
        #expect(reference.value != nil)
        #expect(panel.window === right && !left.isVisible && !right.isVisible && !right.isKeyWindow)
        right.contentView = nil; left.close(); right.close()
    }

    @Test func closedTabsAndTheirModelsAreReleased() async throws {
        _ = NSApplication.shared
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        let scratch = try Scratch("closed-tab-lifetime"), host = NSView(), window = window()
        window.contentView = host
        weak var tabReference: PorpoiseTab?
        weak var paneReference: ViewContainer?
        weak var modelReference: DirectoryModel?
        for _ in 0..<3 {
            var tab: PorpoiseTab? = PorpoiseTab(url: scratch.url, loadsWhenShown: true)
            tabReference = tab; paneReference = tab?.primary; modelReference = tab?.primary.model
            host.addSubview(try #require(tab))
            try #require(await eventually { tab?.primary.model.isLoading == false })
            tab?.removeFromSuperview(); tab = nil
            await mainTurn(); await mainTurn()
            #expect(tabReference == nil && paneReference == nil && modelReference == nil)
        }
        #expect(!window.isVisible && !window.isKeyWindow)
        window.contentView = nil; window.close()
    }

    private final class OtherPreviewOwner: ThumbnailOwner {
        let url: URL
        init(_ url: URL) { self.url = url }
        func showsThumbnail(of url: URL) -> Bool { url == self.url }
    }

    @Test(arguments: [false, true])
    func aParkedInformationPanelStopsOnlyItsOwnRemoteThumbnailInterest(sharedWithAnotherView: Bool) async throws {
        _ = NSApplication.shared
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        Settings.shared.infoShowPreview = true
        Settings.shared.previewImages = true
        Settings.shared.previewRemote = true
        Settings.shared.infoShowHovered = false
        let root = URL(string: "sftp://parked-preview-\(UUID().uuidString.lowercased()).invalid/")!
        let server = GatedServer(png: ThumbnailSchedulingTests.png)
        RemoteFS.use(server, for: root)
        defer { server.open(); RemoteFS.use(nil, for: root) }
        let pane = ViewContainer(url: root)
        try #require(await eventually { !pane.model.isLoading })
        let item = FileItem(url: root.appendingPathComponent("image.png"), name: "image.png", isDirectory: false, size: 100, contentType: "public.png")
        pane.model.searchResults = [item]; pane.model.selection = [item.url]
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        window.contentView = panel
        var publications = 0
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if note.object as? URL == item.url { publications += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        panel.show(hovered: nil, container: pane)
        try #require(await eventually { server.started == 1 })
        let otherOwner = OtherPreviewOwner(item.url)
        if sharedWithAnotherView { _ = Thumbnails.shared.thumbnail(for: item, size: 256, owner: otherOwner) }
        window.contentView = nil
        await mainTurn(); await mainTurn()
        Thumbnails.shared.scheduler.reconcile()
        server.open()
        try #require(await eventually { Thumbnails.shared.outstanding == 0 })
        #expect(sharedWithAnotherView ? publications > 0 : publications == 0)
        #expect(try preview(in: panel).image == nil)
        #expect(server.copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!window.isVisible && !window.isKeyWindow)
        withExtendedLifetime((panel, pane, otherOwner)) {}
        window.close()
    }

    @Test func returningToAParkedColumnResumesTheCurrentSelectionButClearDoesNot() async throws {
        Settings.shared.infoShowPreview = false
        Settings.shared.infoShowHovered = false
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        let scratch = try Scratch(), file = try scratch.file("selected.bin", "fixture")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { pane.model.rows.count == 1 && !pane.model.isLoading })
        pane.list.select(file)
        let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        defer { window.contentView = nil; window.close() }
        window.contentView = column
        column.show(file, container: pane)
        #expect(try preview(in: column.information).image != nil)
        window.contentView = nil
        await mainTurn(); await mainTurn()
        #expect(try preview(in: column.information).image == nil)
        window.contentView = column
        await mainTurn(); await mainTurn()
        #expect(column.shownURL == file)
        #expect(try preview(in: column.information).image != nil)
        column.clear()
        window.contentView = nil
        await mainTurn(); await mainTurn()
        window.contentView = column
        await mainTurn(); await mainTurn()
        #expect(column.shownURL == nil)
        #expect(try preview(in: column.information).image == nil)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func lateColumnSelectionDefersPreviewWorkUntilTheTabReturns() async throws {
        Settings.shared.infoShowPreview = false
        Settings.shared.infoShowHovered = false
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        let scratch = try Scratch(), first = try scratch.file("first.bin", "one"), second = try scratch.file("second.bin", "two")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { pane.model.rows.count == 2 && !pane.model.isLoading })
        pane.list.select(first)
        let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        defer { window.contentView = nil; window.close() }
        window.contentView = column
        column.show(first, container: pane)
        window.contentView = nil
        await mainTurn(); await mainTurn()
        pane.list.select(second)
        column.show(second, container: pane)
        await mainTurn(); await mainTurn()
        #expect(column.shownURL == nil)
        #expect(try preview(in: column.information).image == nil)
        window.contentView = column
        await mainTurn(); await mainTurn()
        #expect(column.shownURL == second)
        #expect(try preview(in: column.information).image != nil)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func delayedHoverCannotRestartAParkedInspector() async throws {
        Settings.shared.infoShowPreview = false
        Settings.shared.infoShowHovered = true
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        let scratch = try Scratch(), file = try scratch.file("hovered.bin", "fixture")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { !pane.model.isLoading })
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600)), window = window()
        defer { window.contentView = nil; window.close() }
        window.contentView = panel
        panel.show(hovered: file, container: pane)
        window.contentView = nil
        // A barrier after the real hover debounce, rather than polling before its callback can run.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { continuation.resume() }
        }
        #expect(try preview(in: panel).image == nil)
        #expect(!panel.showsThumbnail(of: file))
        #expect(!window.isVisible && !window.isKeyWindow)
        withExtendedLifetime(pane) {}
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_MEMORY_BENCHMARK"] == "1"))
    func parkedPreviewMemory() async throws {
        let window = window(), host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = host
        var parked: [ColumnPreviewView] = [], images: [WeakImage] = []
        let before = residentBytes()
        for _ in 0..<24 {
            let column = ColumnPreviewView(frame: host.bounds)
            host.addSubview(column)
            var image: NSImage? = try bitmap(side: 1024)
            images.append(WeakImage(try #require(image)))
            try preview(in: column.information).image = image
            image = nil
            column.removeFromSuperview()
            parked.append(column)
            await mainTurn(); await mainTurn()
        }
        let record: [String: Any] = ["panels": parked.count, "bitmapBytesPerPanel": 1024 * 1024 * 4,
                                    "retainedImages": images.filter { $0.value != nil }.count,
                                    "residentBefore": before, "residentAfterParking": residentBytes()]
        print("PARKED_PREVIEW_MEMORY " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
        #expect(!window.isVisible && !window.isKeyWindow)
        withExtendedLifetime(parked) {}
        window.contentView = nil; window.close()
    }
}
