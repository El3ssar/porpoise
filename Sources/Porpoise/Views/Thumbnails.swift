import AppKit
import QuickLookThumbnailing
import PorpoiseCore
import PorpoiseServices

/// QuickLook previews (Dolphin's "Show Previews"), cached by path + modification date + size.
final class Thumbnails {
    static let shared = Thumbnails()
    static let ready = Notification.Name("PorpoiseThumbnailReady")

    private let cache = NSCache<NSString, NSImage>()
    private var failed = Set<String>()
    private var pending = Set<String>()

    /// Previews are kept up to this many bytes of pixels (they go up to 1024 px, so a count alone isn't a bound).
    private static let cacheBytes = 256 << 20
    /// Bookkeeping sets are bounded too: a long session in big folders must not grow them forever.
    private static let maxRemembered = 20_000

    init() {
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
        guard let t = item.utType else { return false }
        if t.conforms(to: .image) { return s.previewImages }
        if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) { return s.previewVideos }
        if t.conforms(to: .font) { return s.previewFonts }
        if t.conforms(to: .pdf) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) || t.identifier.contains("document")
            || t.conforms(to: .rtf) { return s.previewDocuments }
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

    func folderPreview(for item: FileItem, size: CGFloat) -> NSImage? {
        guard Settings.shared.previewFolders, item.isBrowsableFolder, item.url.isFileURL, size >= 32 else { return nil }
        let size = Self.bucket(size)
        let version = "\(item.url.path)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
        let key = "\(version)|\(Int(size))"
        if let img = folderCache.object(forKey: key as NSString) { return img }
        if folderNone.contains(key) { return nil }
        let candidates = folderPreviewCandidates(item, version: version)
        var thumbs: [NSImage] = []
        var waiting = false
        for c in candidates where thumbs.count < 4 {
            if let t = thumbnail(for: c, size: size / 2, exact: true) { thumbs.append(t) }
            else if !hasFailed(c, size / 2) { waiting = true }
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
                let cell = CGRect(x: inner.minX + CGFloat(i % cols) * (cw + gap), y: inner.minY + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
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
                t.draw(in: CGRect(x: pic.midX - w / 2, y: pic.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
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
    private func folderPreviewCandidates(_ folder: FileItem, version: String) -> [FileItem] {
        if let c = folderCandidates[version] { return c }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let found = Array(names.prefix(80).compactMap { FileItem.load(folder.url.appendingPathComponent($0)) }
            .filter { !$0.isDirectory && Self.wantsPreview($0) }.prefix(8))
        if folderCandidates.count > 2000 { folderCandidates = [:] }
        if folderCandidates.count > Self.maxRemembered / 10 { folderCandidates.removeAll() }
        folderCandidates[version] = found
        return found
    }

    func hasFailed(_ item: FileItem, _ size: CGFloat) -> Bool { failed.contains(key(item, size)) }

    /// Settings changed: forget folder previews so they are rebuilt (or dropped).
    func resetFolderPreviews() {
        folderCache.removeAllObjects()
        folderLatest.removeAllObjects()
        folderNone = []
        folderCandidates = [:]
    }

    /// A frame a few seconds in (or the first one for short clips), scaled to fit `size` pixels.
    static func ffmpegFrame(_ url: URL, size: CGFloat) -> NSImage? {
        guard let ff = VideoPreview.ffmpeg else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let s = Int(size)
        for start in ["3", "0"] {
            _ = try? Shell.run(ff, ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", start, "-i", "file:" + url.path, "-frames:v", "1",
                                    "-vf", "scale='min(\(s),iw)':'min(\(s),ih)':force_original_aspect_ratio=decrease", "-y", out.path], timeout: 15)
            if let img = NSImage(contentsOf: out) { return img }
        }
        return nil
    }

    /// Returns a cached thumbnail, or nil and starts generating one (posting `ready` when done).
    /// `exact`: only the requested size (folder previews compose from these), no stand-in.
    func thumbnail(for item: FileItem, size: CGFloat, exact: Bool = false) -> NSImage? {
        let k = key(item, size)
        if let img = cache.object(forKey: k as NSString) { return img }
        if failed.contains(k) { return nil }
        if pending.contains(k) { return exact ? nil : anyCached(item, near: size) }
        pending.insert(k)
        if item.url.isFileURL {
            generate(k, for: item, file: item.url, size: size)
        } else {
            // Settings › Previews › remote files: Quick Look needs a local file, so fetch a temporary copy first
            // (one at a time: a folder of photos must not open dozens of connections).
            let remote = item.url
            Self.remoteQueue.async { [weak self] in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-preview-\(UUID().uuidString)")
                let local = try? RemoteFS.provider(for: remote)?.download(remote, into: dir)
                DispatchQueue.main.async {
                    guard let self else { try? FileManager.default.removeItem(at: dir); return }
                    if let local {
                        self.generate(k, for: item, file: local, size: size, cleanup: dir)
                    } else {
                        try? FileManager.default.removeItem(at: dir)
                        self.pending.remove(k)
                        self.failed.insert(k)
                        NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                    }
                }
            }
        }
        return exact ? nil : anyCached(item, near: size)
    }

    /// Remote previews download one file at a time.
    private static let remoteQueue = DispatchQueue(label: "porpoise.remote-previews", qos: .utility)

    /// Makes the preview of `file` (the item itself, or a local copy of a remote item, removed with `cleanup` after).
    private func generate(_ k: String, for item: FileItem, file: URL, size: CGFloat, cleanup: URL? = nil) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let gen = Self.bucket(size)
        let req = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: gen, height: gen), scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let rep {
                    self.pending.remove(k)
                    self.store(rep.nsImage, k)
                    NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                } else if VideoPreview.isVideoExtension(item.fileExtension), item.url.isFileURL, VideoPreview.ffmpeg != nil {
                    // Quick Look can't read MKV/WebM/AVI…: grab a frame with ffmpeg. Still pending meanwhile,
                    // or every repaint would start another Quick Look request and ffmpeg run.
                    DispatchQueue.global(qos: .utility).async {
                        let img = Self.ffmpegFrame(item.url, size: gen * scale)
                        DispatchQueue.main.async {
                            self.pending.remove(k)
                            if let img { self.store(img, k) } else { self.remember(failed: k) }
                            NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                        }
                    }
                } else {
                    self.pending.remove(k)
                    self.remember(failed: k)
                    // Folder previews wait on every candidate; tell them this one won't come.
                    NotificationCenter.default.post(name: Thumbnails.ready, object: item.url)
                }
            }
        }
    }
}
