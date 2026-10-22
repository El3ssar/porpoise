import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import QuickLookThumbnailing

/// QuickLook previews (Dolphin's "Show Previews"), cached by path + modification date + size.
final class Thumbnails {
    static let shared = Thumbnails()
    static let ready = Notification.Name("PorpoiseThumbnailReady")

    private let cache = NSCache<NSString, NSImage>()
    private var failed = Set<String>()
    private var pending = Set<String>()
    private var retryAfter: [String: Date] = [:]
    /// Runs the work behind `pending`: bounded per kind, dropped or cancelled once no owner shows the item.
    let scheduler: ThumbnailWorkScheduler

    /// Previews are kept up to this many bytes of pixels (they go up to 1024 px, so a count alone isn't a bound).
    private static let cacheBytes = 256 << 20
    /// Bookkeeping sets are bounded too: a long session in big folders must not grow them forever.
    private static let maxRemembered = 20_000

    init(scheduler: ThumbnailWorkScheduler = ThumbnailWorkScheduler()) {
        self.scheduler = scheduler
        cache.countLimit = 3000
        cache.totalCostLimit = Self.cacheBytes
        folderCache.totalCostLimit = Self.cacheBytes / 4
        folderLatest.totalCostLimit = Self.cacheBytes / 8
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in self?.resetFolderPreviews() }
    }

    private func store(_ img: NSImage, _ key: String) { cache.setObject(img, forKey: key as NSString, cost: Self.cost(of: img)) }

    private func remember(failed key: String) {
        if failed.count > Self.maxRemembered { failed.removeAll() }
        failed.insert(key)
    }

    /// Bytes of pixels an image holds (its largest representation).
    private static func cost(of img: NSImage) -> Int {
        let px = img.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(1, (px > 0 ? px : Int(img.size.width * img.size.height)) * 4)
    }

    /// Previews are made in a few fixed sizes and scaled when drawn, so zooming reuses them instead of flickering.
    static let buckets: [CGFloat] = [32, 64, 128, 256, 512, 1024]
    static func bucket(_ s: CGFloat) -> CGFloat { buckets.first { $0 >= s } ?? 1024 }

    private func key(_ item: FileItem, _ size: CGFloat) -> String {
        // The whole URL for remote items: the same path on two servers is two files.
        "\(item.url.isFileURL ? item.url.path : item.url.absoluteString)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(Int(Self.bucket(size)))"
    }

    /// Any already-made preview of the item (nearest size first), shown while the right size is generated.
    private func anyCached(_ item: FileItem, near size: CGFloat) -> NSImage? {
        let b = Self.bucket(size)
        let order = Self.buckets.sorted { abs($0 - b) < abs($1 - b) || (abs($0 - b) == abs($1 - b) && $0 > $1) }
        for s in order where s != b {
            if let img = cache.object(forKey: key(item, s) as NSString) { return img }
        }
        return nil
    }

    /// Whether Dolphin would try a preview for this item (images, video, PDFs, documents, text…).
    static func wantsPreview(_ item: FileItem) -> Bool {
        let s = Settings.shared
        if item.isBrowsableFolder || item.isApplication || item.isPackage { return false }
        if !item.url.isFileURL && !s.previewRemote { return false }
        // The size limit spares big documents and images; a local video frame costs the same at any file size,
        // a remote one means downloading the whole file.
        let isVideo = VideoPreview.isVideoExtension(item.fileExtension) || item.utType?.conforms(to: .movie) == true
        if !isVideo || !item.url.isFileURL, s.previewMaxSizeMiB > 0 && item.size > Int64(s.previewMaxSizeMiB) * 1024 * 1024 { return false }
        if VideoPreview.isVideoExtension(item.fileExtension) { return s.previewVideos }
        if item.url.scheme == "gdrive", item.contentType?.hasPrefix("com.google.apps.") == true { return s.previewDocuments }
        guard let t = item.utType else { return false }
        if t.conforms(to: .image) { return s.previewImages }
        if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) { return s.previewVideos }
        if t.conforms(to: .font) { return s.previewFonts }
        if t.conforms(to: .pdf) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) || t.identifier.contains("document")
            || t.conforms(to: .rtf)
        {
            return s.previewDocuments
        }
        if t.conforms(to: .text) { return s.previewText }
        return t.conforms(to: .threeDContent) && s.previewDocuments
    }

    /// Folder preview (Settings › Previews › Folders): the folder icon with up to four previews of its files on top,
    /// like Dolphin's directory thumbnailer.
    private let folderCache = NSCache<NSString, NSImage>()
    private var folderNone = Set<String>()
    /// The last preview made of a folder version, at any size: shown while another size is being made.
    private let folderLatest = NSCache<NSString, NSImage>()
    /// Files a folder's preview is made from, per folder version: listing them is disk I/O, and drawing asks
    /// again on every repaint until all their previews are ready.
    private var folderCandidates: [String: [FileItem]] = [:]
    /// Folder versions whose candidates are being listed. Never while drawing: a folder can hold 100,000 files.
    private var folderScans = Set<String>()
    /// Bumped by `resetFolderPreviews()`: a listing started before is thrown away.
    private var folderGeneration = 0
    private static let folderScanQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "porpoise.thumbnails.folders"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 2
        return q
    }()

    func folderPreview(for item: FileItem, size: CGFloat, owner: ThumbnailOwner? = nil) -> NSImage? {
        guard Settings.shared.previewFolders, item.isBrowsableFolder, item.url.isFileURL, size >= 32 else { return nil }
        let size = Self.bucket(size)
        let version = "\(item.url.path)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
        let key = "\(version)|\(Int(size))"
        if let img = folderCache.object(forKey: key as NSString) { return img }
        if folderNone.contains(key) { return nil }
        // Still listing: the last preview made at another size meanwhile, else the plain folder.
        guard let candidates = folderPreviewCandidates(item, version: version) else { return folderLatest.object(forKey: version as NSString) }
        var thumbs: [NSImage] = []
        var waiting = false
        for c in candidates where thumbs.count < 4 {
            if let t = thumbnail(for: c, size: size / 2, exact: true, owner: owner, shownAs: item.url) {
                thumbs.append(t)
            } else if !hasFailed(c, size / 2) {
                waiting = true
            }
        }
        // Not all previews ready yet: keep showing the last one made at another size (no flicker while zooming).
        if thumbs.count < 4 && waiting { return folderLatest.object(forKey: version as NSString) }
        guard !thumbs.isEmpty else {
            if folderNone.count > Self.maxRemembered { folderNone.removeAll() }
            folderNone.insert(key)
            return nil
        }
        let base = Icons.shared.image(for: item, size: size)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            base.draw(in: r)
            // The front face of the Tela folder: previews sit on it like photos in a folder.
            let inner = CGRect(x: r.width * 0.17, y: r.height * 0.34, width: r.width * 0.66, height: r.height * 0.5)
            let n = thumbs.count
            let cols = n == 1 ? 1 : 2, rows = n <= 2 ? 1 : 2
            let gap = max(1.5, size / 64)
            let cw = (inner.width - gap * CGFloat(cols - 1)) / CGFloat(cols), ch = (inner.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for (i, t) in thumbs.enumerated() {
                let cell = CGRect(
                    x: inner.minX + CGFloat(i % cols) * (cw + gap), y: inner.minY + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
                let radius = max(1.5, size / 48)
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow(); sh.shadowBlurRadius = max(1, size / 64); sh.shadowOffset = NSSize(width: 0, height: -0.5)
                sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.set()
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                let pic = cell.insetBy(dx: max(0.75, size / 128), dy: max(0.75, size / 128))
                NSBezierPath(roundedRect: pic, xRadius: radius * 0.7, yRadius: radius * 0.7).addClip()
                let ts = t.size, sc = max(pic.width / max(1, ts.width), pic.height / max(1, ts.height))
                let w = ts.width * sc, h = ts.height * sc
                t.draw(
                    in: CGRect(x: pic.midX - w / 2, y: pic.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        folderCache.setObject(img, forKey: key as NSString, cost: Self.cost(of: img))
        folderLatest.setObject(img, forKey: version as NSString, cost: Self.cost(of: img))
        return img
    }

    /// Up to 8 previewable files among the first 80 visible entries (in name order), cached per folder version.
    /// Nil while they are listed on a worker queue; `ready` is posted for the folder when they are known.
    private func folderPreviewCandidates(_ folder: FileItem, version: String) -> [FileItem]? {
        if let c = folderCandidates[version] { return c }
        guard folderScans.insert(version).inserted else { return nil }
        let url = folder.url, generation = folderGeneration
        Self.folderScanQueue.addOperation { [weak self] in
            let files = Self.firstNames(in: url, count: 80).compactMap { FileItem.load(url.appendingPathComponent($0)) }.filter { !$0.isDirectory }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.folderGeneration else { return }
                self.folderScans.remove(version)
                if self.folderCandidates.count > Self.maxRemembered / 10 { self.folderCandidates.removeAll() }
                self.folderCandidates[version] = Array(files.filter(Self.wantsPreview).prefix(8))
                NotificationCenter.default.post(name: Thumbnails.ready, object: url)
            }
        }
        return nil
    }

    /// The first `count` visible names in name order (Finder's), without sorting them all.
    static func firstNames(in folder: URL, count: Int) -> [String] {
        var first: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
            if first.count == count {
                guard name.localizedStandardCompare(first[count - 1]) == .orderedAscending else { continue }
                first.removeLast()
            }
            var lo = 0, hi = first.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if first[mid].localizedStandardCompare(name) == .orderedAscending { lo = mid + 1 } else { hi = mid }
            }
            first.insert(name, at: lo)
        }
        return first
    }

    func hasFailed(_ item: FileItem, _ size: CGFloat) -> Bool { failed.contains(key(item, size)) }

    /// Previews asked for and not made yet (queued, running, or handed between steps).
    var outstanding: Int { pending.count }

    /// Settings changed: forget folder previews so they are rebuilt (or dropped).
    func resetFolderPreviews() {
        folderCache.removeAllObjects()
        folderLatest.removeAllObjects()
        folderNone = []
        folderCandidates = [:]
        folderScans = []
        folderGeneration += 1
    }

    /// A frame a few seconds in (or the first one for short clips), scaled to fit `size` pixels. ffmpeg is stopped
    /// once `isCancelled` says so.
    static func ffmpegFrame(_ url: URL, size: CGFloat, isCancelled: @escaping () -> Bool = { false }) -> NSImage? {
        guard let ff = VideoPreview.ffmpeg else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let s = Int(size)
        let control = Shell.TransferControl(isPaused: { false }, isCancelled: isCancelled)
        for start in ["3", "0"] where !isCancelled() {
            _ = try? Shell.withTransferControl(control) {
                try Shell.run(
                    ff,
                    [
                        "-hide_banner", "-loglevel", "error", "-nostdin", "-ss", start, "-i", "file:" + url.path, "-frames:v", "1",
                        "-vf", "scale='min(\(s),iw)':'min(\(s),ih)':force_original_aspect_ratio=decrease", "-y", out.path,
                    ], timeout: 15)
            }
            if !isCancelled(), let img = NSImage(contentsOf: out) { return img }
        }
        return nil
    }

    /// Returns a cached thumbnail, or nil and starts generating one (posting `ready` when done).
    /// `exact`: only the requested size (folder previews compose from these), no stand-in.
    /// `owner` draws it (at `shownAs`, the folder a folder preview is made for): the work is dropped or cancelled once
    /// it no longer shows the item. Without one it's wanted until done.
    func thumbnail(for item: FileItem, size: CGFloat, exact: Bool = false, owner: ThumbnailOwner? = nil, shownAs: URL? = nil) -> NSImage? {
        let k = key(item, size)
        if let img = cache.object(forKey: k as NSString) { return img }
        if let retry = retryAfter[k] {
            if retry > Date() { return nil }
            retryAfter[k] = nil
        }
        if failed.contains(k) { return nil }
        let interest = ThumbnailWorkScheduler.Interest(owner: owner, url: shownAs ?? item.url)
        if pending.contains(k) {
            scheduler.touch(k, interest: interest)
            return exact ? nil : anyCached(item, near: size)
        }
        pending.insert(k)
        let dropped = { [weak self] in _ = self?.pending.remove(k) }
        if item.url.isFileURL {
            scheduler.submit(
                k, lane: .preview, interest: interest, body: { [weak self] job in self?.generate(job, for: item, file: item.url, size: size) },
                dropped: dropped)
        } else {
            // A cloud service's thumbnail, or (Settings › Previews › remote files) a temporary copy of a server's file
            // for Quick Look.
            let remote = item.url
            scheduler.submit(
                k, lane: PreviewSource.isProgressive(remote) ? .cloud : .server, interest: interest,
                body: { [weak self] job in self?.fetch(job, for: item, size: size) }, dropped: dropped)
        }
        return exact ? nil : anyCached(item, near: size)
    }

    /// Fetches what a remote item's preview is made from, then makes it (or keeps the cloud's own thumbnail).
    private func fetch(_ job: ThumbnailWorkScheduler.Job, for item: FileItem, size: CGFloat) {
        let k = job.key, remote = item.url
        let task = Task { @MainActor [weak self] in
            let local = try? await PreviewSource.localFile(for: remote, thumbnail: true)
            guard let self, !job.isCancelled else {
                if let dir = local?.cleanup { try? FileManager.default.removeItem(at: dir) }
                _ = self?.pending.remove(k)
                job.finish()
                return
            }
            if let local, local.cleanup == nil, let image = NSImage(contentsOf: local.file) {
                self.pending.remove(k)
                self.store(image, k)
                NotificationCenter.default.post(name: Thumbnails.ready, object: remote)
                job.finish()
            } else if let local {
                self.scheduler.hand(
                    job, to: .preview,
                    body: { [weak self] job in self?.generate(job, for: item, file: local.file, size: size, cleanup: local.cleanup) },
                    dropped: { [weak self] in
                        if let dir = local.cleanup { try? FileManager.default.removeItem(at: dir) }
                        _ = self?.pending.remove(k)
                    })
            } else {
                self.pending.remove(k)
                if let delay = PreviewSource.retryDelay(for: remote) {
                    if self.retryAfter.count > Self.maxRemembered { self.retryAfter.removeAll() }
                    self.retryAfter[k] = Date().addingTimeInterval(delay)
                } else {
                    self.remember(failed: k)
                }
                NotificationCenter.default.post(name: Thumbnails.ready, object: remote)
                job.finish()
            }
        }
        job.onCancel { task.cancel() }
    }

    /// PDF thumbnail generators may return transparent paper, which hides black text in dark mode.
    static func paperPreview(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            image.draw(in: rect)
            return true
        }
    }

    /// Makes the preview of `file` (the item itself, or a local copy of a remote item, removed with `cleanup` after).
    /// Cancelled work publishes nothing: the item is asked for again when it's drawn again.
    private func generate(_ job: ThumbnailWorkScheduler.Job, for item: FileItem, file: URL, size: CGFloat, cleanup: URL? = nil) {
        let k = job.key
        // Audio: its cover, else the theme's icon (Quick Look would draw a generic tile).
        if let t = item.utType, t.conforms(to: .audio), !t.conforms(to: .movie) {
            let task = Task {
                let image = await AudioArtwork.load(file).flatMap(NSImage.init(data:))
                await MainActor.run {
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    self.pending.remove(k)
                    defer { job.finish() }
                    guard !job.isCancelled else { return }
                    if let image { self.store(image, k) } else { self.remember(failed: k) }
                    NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                }
            }
            job.onCancel { task.cancel() }
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let gen = Self.bucket(size)
        let req = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: gen, height: gen), scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            DispatchQueue.main.async {
                guard let self else { return }
                if job.isCancelled {
                    self.pending.remove(k)
                    job.finish()
                } else if let rep {
                    self.pending.remove(k)
                    let image = item.url.scheme == "gdrive" && file.pathExtension == "pdf" ? Self.paperPreview(rep.nsImage) : rep.nsImage
                    self.store(image, k)
                    NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                    job.finish()
                } else if VideoPreview.isVideoExtension(item.fileExtension), item.url.isFileURL, VideoPreview.ffmpeg != nil {
                    // Quick Look can't read MKV/WebM/AVI…: grab a frame with ffmpeg. Still pending meanwhile,
                    // or every repaint would start another Quick Look request and ffmpeg run.
                    self.scheduler.hand(
                        job, to: .video, body: { [weak self] job in self?.extractFrame(job, for: item, size: gen * scale) },
                        dropped: { [weak self] in _ = self?.pending.remove(k) })
                } else {
                    self.pending.remove(k)
                    self.remember(failed: k)
                    // Folder previews wait on every candidate; tell them this one won't come.
                    NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                    job.finish()
                }
            }
        }
        // A cancelled request still calls back (without a representation), which frees the job's slot.
        job.onCancel { QLThumbnailGenerator.shared.cancel(req) }
    }

    /// A video's ffmpeg frame, on a queue of its own: ffmpeg is waited for there, never on a shared pool's thread.
    private func extractFrame(_ job: ThumbnailWorkScheduler.Job, for item: FileItem, size: CGFloat) {
        let k = job.key, url = item.url
        let cancelled = ThumbnailWorkScheduler.Flag()
        job.onCancel { cancelled.set() }
        DispatchQueue(label: "porpoise.thumbnails.video", qos: .utility).async { [weak self] in
            let img = Self.ffmpegFrame(url, size: size) { cancelled.isSet }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(k)
                defer { job.finish() }
                guard !job.isCancelled else { return }
                if let img { self.store(img, k) } else { self.remember(failed: k) }
                NotificationCenter.default.post(name: Thumbnails.ready, object: url)
            }
        }
    }
}
