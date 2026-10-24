import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Thumbnail work has one owner: each kind runs a few at a time, waiting work stays bounded, and work for items
/// scrolled away (or in a list that's gone) is dropped or cancelled and never published.
@Suite(.serialized) struct ThumbnailSchedulingTests {
    /// A list showing the rows in `shown`; its items are `item-<row>`.
    final class Viewport: ThumbnailOwner {
        var shown: Range<Int> = 0..<0
        func showsThumbnail(of url: URL) -> Bool { Viewport.row(url).map(shown.contains) ?? false }
        static func row(_ url: URL) -> Int? { Int(url.deletingPathExtension().lastPathComponent.dropFirst("item-".count)) }
    }

    @Test @MainActor func rapidScrollingThroughRemoteAndVideoItemsStaysBoundedAndPublishesNothingStale() {
        // A small waiting bound, and drawing far more often than the stale work is swept: overflow sweeps it too.
        let scheduler = ThumbnailWorkScheduler(limits: .init(pending: 64))
        let viewport = Viewport()
        var running: [ThumbnailWorkScheduler.Job] = []
        var peak: [ThumbnailWorkScheduler.Lane: Int] = [:]
        var peakPending = 0, started = 0, dropped = 0, cancelled = 0
        var published: [Int] = [], stale: [Int] = []
        let lanes: [ThumbnailWorkScheduler.Lane] = [.server, .video, .cloud, .preview]
        func url(_ row: Int) -> URL { URL(string: "sftp://thumbs.invalid/item-\(row).mkv")! }
        /// The oldest running work of each lane comes back (a slow server, ffmpeg, a cloud API).
        func completeSome() {
            for lane in lanes {
                guard let job = running.first(where: { $0.lane == lane }) else { continue }
                running.removeAll { $0 === job }
                if job.isCancelled {
                    cancelled += 1
                } else {
                    let row = Viewport.row(url(Int(job.key)!))!
                    published.append(row)
                    if !viewport.shown.contains(row) { stale.append(row) }
                }
                job.finish()
            }
        }
        var plateau: [Int] = []
        // 10,000 rows, 40 on screen, scrolled 20 rows at a time: far faster than the work comes back.
        for step in 0..<500 {
            viewport.shown = step * 20..<step * 20 + 40
            for row in viewport.shown {
                scheduler.submit(
                    "\(row)", lane: lanes[row % lanes.count], interest: .init(owner: viewport, url: url(row)),
                    body: { job in
                        started += 1
                        running.append(job)
                        peak[job.lane] = max(peak[job.lane] ?? 0, scheduler.runningCount(job.lane))
                    }, dropped: { dropped += 1 })
                peakPending = max(peakPending, scheduler.pendingCount)
            }
            if step % 5 == 4 { scheduler.reconcile() }
            completeSome()
            if step % 100 == 99 { plateau.append(scheduler.pendingCount + running.count) }
        }
        let limits = scheduler.limits.active
        for lane in lanes { #expect((peak[lane] ?? 0) <= limits[lane]!, "\(lane) ran \(peak[lane] ?? 0) at once") }
        #expect(peak[.server] == 1 && peak[.video] == 2)
        #expect(peakPending <= scheduler.limits.pending)
        #expect(stale.isEmpty, "published rows no longer shown: \(stale.prefix(10))")
        #expect(cancelled > 0 && dropped > 0 && !published.isEmpty)
        // Outstanding work doesn't grow with the distance scrolled.
        #expect(plateau.allSatisfy { $0 <= 64 + 15 }, "\(plateau)")
        // Everything settles once scrolling stops: nothing is lost track of.
        while !running.isEmpty || scheduler.pendingCount > 0 {
            scheduler.reconcile()
            completeSome()
        }
        #expect(started == published.count + cancelled)
    }

    @Test @MainActor func workForAListThatWentAwayIsDropped() {
        let scheduler = ThumbnailWorkScheduler(limits: .init(active: [.preview: 1], pending: 8))
        var viewport: Viewport? = Viewport()
        viewport!.shown = 0..<100
        var started: [String] = [], dropped: [String] = []
        for row in 0..<3 {
            scheduler.submit(
                "\(row)", lane: .preview, interest: .init(owner: viewport, url: URL(fileURLWithPath: "/item-\(row).png")),
                body: { started.append($0.key) }, dropped: { dropped.append("\(row)") })
        }
        #expect(started == ["0"] && scheduler.pendingCount == 2)
        viewport = nil
        scheduler.reconcile()
        #expect(dropped == ["1", "2"] && scheduler.pendingCount == 0)
        // Ownerless work (the Information panel's) is always wanted; the oldest waiting goes first when full.
        for row in 10..<20 {
            scheduler.submit(
                "\(row)", lane: .preview, interest: .init(owner: nil, url: URL(fileURLWithPath: "/\(row)")), body: { _ in },
                dropped: { dropped.append("\(row)") })
        }
        #expect(scheduler.pendingCount == 8 && dropped.suffix(2) == ["10", "11"])
    }

    @Test @MainActor func aListOutOfAWindowShowsNoThumbnails() throws {
        let scratch = try Scratch()
        let list = ItemListView(model: DirectoryModel(location: scratch.url, prefetchFolders: false))
        #expect(!list.showsThumbnail(of: scratch.url.appendingPathComponent("a.png")))
    }

    /// The retained acceptance from the perf audit: every local PNG gets its preview with Quick Look capped at 8.
    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func localImagesAllGetPreviewsWithinTheQuickLookBound() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let items = try (0..<100).map { i in
            let url = scratch.url.appendingPathComponent("image-\(i).png")
            try Self.png.write(to: url)
            return try #require(FileItem.load(url))
        }
        let thumbnails = Thumbnails()
        for item in items { _ = thumbnails.thumbnail(for: item, size: 128) }
        #expect(thumbnails.scheduler.runningCount(.preview) == 8 && thumbnails.scheduler.pendingCount == 92)
        await expectEventually { thumbnails.outstanding == 0 }
        // Every one settles. Quick Look's own cache now and then refuses a fresh file whose inode it saw before ("no
        // backing ubiquitous item"), so a couple may fail here; the release probe holds the 100 of 100.
        let made = items.filter { thumbnails.thumbnail(for: $0, size: 128) != nil }.count
        #expect(made + items.filter { thumbnails.hasFailed($0, 128) }.count == 100 && made >= 97, "\(made) of 100")
    }

    /// A server's photos: one download at a time, and those scrolled away before their turn are never fetched; the
    /// one already downloading is thrown away instead of shown.
    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func scrolledAwayServerPreviewsAreNeitherFetchedNorPublished() async throws {
        _ = NSApplication.shared
        Settings.shared.previewRemote = true
        let root = URL(string: "sftp://thumbs-\(UUID().uuidString.prefix(8).lowercased()).invalid/")!
        let server = GatedServer(png: Self.png)
        RemoteFS.use(server, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let items = (0..<30).map {
            FileItem(url: root.appendingPathComponent("item-\($0).png"), name: "item-\($0).png", isDirectory: false, size: 100)
        }
        let thumbnails = Thumbnails()
        let viewport = Viewport()
        var ready: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let u = n.object as? URL, let row = Viewport.row(u) { ready.append(row) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        viewport.shown = 0..<10
        for row in viewport.shown { _ = thumbnails.thumbnail(for: items[row], size: 64, owner: viewport) }
        await expectEventually { server.started == 1 }
        // Scrolled on while the first is still downloading.
        viewport.shown = 20..<30
        for row in viewport.shown { _ = thumbnails.thumbnail(for: items[row], size: 64, owner: viewport) }
        // The first still downloads (cancelled), the ten now shown wait; the nine scrolled past are dropped.
        await expectEventually { thumbnails.outstanding == 11 && thumbnails.scheduler.pendingCount == 10 }
        server.open()
        await expectEventually { thumbnails.outstanding == 0 }
        #expect(server.peak == 1)
        #expect(server.fetched.sorted() == ["item-0.png"] + (20..<30).map { "item-\($0).png" }.sorted())
        #expect(Set(ready) == Set(20..<30), "published \(ready.sorted())")
        #expect(server.copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "downloaded copies are removed")
        // Scrolling back asks again.
        viewport.shown = 0..<10
        #expect(thumbnails.thumbnail(for: items[0], size: 64, owner: viewport) == nil)
        await expectEventually { thumbnails.thumbnail(for: items[0], size: 64, owner: viewport) != nil }
    }

    /// Videos Quick Look can't read: two ffmpeg runs at a time, stopped once scrolled away, their frames never shown.
    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func scrolledAwayVideoFramesAreStoppedAndNotPublished() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let frame = scratch.url.appendingPathComponent("frame.png")
        try Self.png.write(to: frame)
        let log = scratch.url.appendingPathComponent("runs.log")
        // Stands in for ffmpeg: logs its run, takes a while, then writes the frame to its last argument.
        let tool = scratch.url.appendingPathComponent("fake-ffmpeg")
        try """
        #!/bin/sh
        for last; do :; done
        echo "start $$" >> '\(log.path)'
        sleep 0.4
        cp '\(frame.path)' "$last"
        """.write(to: tool, atomically: true, encoding: .utf8)
        #expect(chmod(tool.path, 0o755) == 0)
        let saved = VideoPreview.testFFmpeg
        VideoPreview.testFFmpeg = tool.path
        defer { VideoPreview.testFFmpeg = saved }
        let items = try (0..<20).map { i in
            let url = scratch.url.appendingPathComponent("item-\(i).mkv")
            try Data("not a video".utf8).write(to: url)
            return try #require(FileItem.load(url))
        }
        let cache = RecordingThumbnailCache()
        let thumbnails = Thumbnails(cache: cache)
        let viewport = Viewport()
        var ready: [Int] = [], peak = 0
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let url = n.object as? URL, let row = items.firstIndex(where: { $0.url == url }) else { return }
                ready.append(row)
                #expect(cache.stored.count == ready.count, "every ready follows its frame's cache insertion")
                // NSCache can evict under pressure. Force it here, after publication, instead of relying on load.
                cache.removeAllObjects()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        viewport.shown = 0..<10
        for row in viewport.shown { _ = thumbnails.thumbnail(for: items[row], size: 64, owner: viewport) }
        await expectEventually {
            peak = max(peak, thumbnails.scheduler.runningCount(.video))
            return thumbnails.scheduler.runningCount(.video) == 2
        }
        viewport.shown = 15..<20
        for row in viewport.shown { _ = thumbnails.thumbnail(for: items[row], size: 64, owner: viewport) }
        await expectEventually {
            peak = max(peak, thumbnails.scheduler.runningCount(.video))
            return thumbnails.outstanding == 0
        }
        #expect(peak <= 2)
        #expect(Set(ready) == Set(15..<20), "published \(ready.sorted())")
        // Check generation independently of an evictable cache. The observer checks store-before-publication.
        #expect(cache.stored.count == 5)
        #expect(cache.stored.allSatisfy { $0.image.size == NSSize(width: 64, height: 64) })
        #expect(items[15..<20].allSatisfy { !thumbnails.hasFailed($0, 64) })
        #expect(cache.stored.allSatisfy { cache.object(forKey: $0.key) == nil }, "eviction was exercised")
        // The two running when scrolled away were stopped, the rest of the first screen never started.
        let runs = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count ?? 0
        #expect((5...2 + 5 + 2).contains(runs), "\(runs) ffmpeg runs")
    }

    @Test(.timeLimit(.minutes(2))) func cancellingAVideoFrameStopsFfmpeg() async throws {
        let scratch = try Scratch()
        let tool = scratch.url.appendingPathComponent("stuck-ffmpeg")
        let pidFile = scratch.url.appendingPathComponent("ffmpeg.pid")
        try "#!/bin/sh\nprintf '%s\\n' \"$$\" > '\(pidFile.path)'\nexec /bin/sleep 86400\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        #expect(chmod(tool.path, 0o755) == 0)
        let saved = VideoPreview.testFFmpeg
        VideoPreview.testFFmpeg = tool.path
        defer { VideoPreview.testFFmpeg = saved }
        let video = scratch.url.appendingPathComponent("clip.mkv")
        #expect(Thumbnails.ffmpegFrame(video, size: 64) { true } == nil)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        let flag = ThumbnailWorkScheduler.Flag()
        defer {
            flag.set()
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(pid, SIGKILL)
            }
        }
        let stopped = Task {
            try await awaitCallback("cancellation never ended ffmpeg") { (done: Callback<Bool>) in
                DispatchQueue(label: "test.ffmpeg").async {
                    // Only cancellation can end this tool during the test: its ordinary timeout is disabled.
                    done.resume(returning: Thumbnails.ffmpegFrame(video, size: 64, timeout: 0) { flag.isSet } == nil)
                }
            }
        }
        var child: pid_t?
        try #require(
            await poll {
                child = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return child != nil
            })
        let pid = try #require(child)
        #expect(kill(pid, 0) == 0)
        flag.set()
        #expect(try await stopped.value)
        let status = kill(pid, 0), error = errno
        #expect(status == -1 && error == ESRCH)
    }

    static let png: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }()
}

/// A server whose downloads wait until `open()`, counting how many run at once.
final class GatedServer: RemoteProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let png: Data
    private var isOpen = false
    private var active = 0
    private(set) var started = 0
    private(set) var peak = 0
    private(set) var fetched: [String] = []
    private(set) var copies: [URL] = []
    init(png: Data) { self.png = png }

    func open() {
        lock.withLock { isOpen = true }
        gate.signal()
    }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let waits = lock.withLock {
            started += 1; active += 1; peak = max(peak, active)
            return !isOpen
        }
        if waits { gate.wait() }
        defer { lock.withLock { active -= 1 } }
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let local = localFolder.appendingPathComponent(remote.lastPathComponent)
        try png.write(to: local)
        lock.withLock {
            fetched.append(remote.lastPathComponent)
            copies.append(localFolder)
        }
        return local
    }

    func list(_ folder: URL) throws -> [FileItem] { [] }
    func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
    func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
    func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "thumbs" }
}

/// Keeps the generated values independently of NSCache's discretionary retention, to check publication order.
private final class RecordingThumbnailCache: NSCache<NSString, NSImage>, @unchecked Sendable {
    private(set) var stored: [(key: NSString, image: NSImage)] = []

    override func setObject(_ image: NSImage, forKey key: NSString, cost: Int) {
        stored.append((key, image))
        super.setObject(image, forKey: key, cost: cost)
    }
}
