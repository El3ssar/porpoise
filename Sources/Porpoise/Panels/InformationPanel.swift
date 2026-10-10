import AppKit
import AVKit
import PorpoiseCore

/// Dolphin's Information panel (F10 here): large preview, name and metadata of the hovered item, the selection,
/// or the current folder.
final class InformationPanel: NSView {
    private let preview = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let grid = NSStackView()
    /// Inspector look: same tinted material as the sidebar.
    private let material = TintedMaterialView(material: .sidebar, alpha: 0.72)
    /// Dolphin's information panel plays audio/video inline. The view shows no controls of its own (see MediaControls).
    private let player = AVPlayerView()
    private let controls = MediaControls()
    /// The pointer is over the video (its controls show while it is, and whenever it's paused).
    private var overVideo = false
    private var hoverArea: NSTrackingArea?

    private var shownURLs: [URL] = []
    /// Where the shown items come from (remote items and the selection are looked up in its model), and the
    /// hovered item, so a settings change can re-decide what to show.
    private weak var container: ViewContainer?
    private var hoveredURL: URL?
    /// File the player is set up for (a re-render of the same file keeps it playing).
    private var playerURL: URL?
    private var playerIsAudio = false
    /// The thumbnail, kept over the video until playback starts (no jump from thumbnail to first frame).
    private let poster = NSImageView()
    private var playObservation: NSKeyValueObservation?
    private var playerWork: DispatchWorkItem?
    private var thumbnailObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    /// Spotlight attributes, keyed by path and modification date so edited files are re-read.
    private var metadataCache: [String: [(String, String)]] = [:]

    private static let previewSize: CGFloat = 256
    private static let maxPreviewSide: CGFloat = 220
    private static let metadataCacheLimit = 500
    /// The player starts once the pointer settles (hovering across many files must not open each one).
    private static let playerDelay: TimeInterval = 0.25
    private static let condensed: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        preview.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = Theme.windowText
        nameLabel.alignment = .center
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        addSubview(material)
        player.controlsStyle = .none
        player.isHidden = true
        player.wantsLayer = true
        player.layer?.cornerRadius = 8
        player.layer?.masksToBounds = true
        // Clicking the video plays or pauses it.
        player.addGestureRecognizer(NSClickGestureRecognizer(target: controls, action: #selector(MediaControls.togglePlay)))
        controls.isHidden = true
        [preview, player, controls, nameLabel, grid].forEach(addSubview)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        [thumbnailObserver, windowCloseObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        playerWork?.cancel()
    }

    override func draw(_ dirty: NSRect) {}

    override func layout() {
        super.layout()
        material.frame = bounds
        let w = bounds.width
        let side = min(w - 40, Self.maxPreviewSide)
        preview.frame = CGRect(x: (w - side) / 2, y: 16, width: side, height: Settings.shared.infoShowPreview ? side : 0)
        // Decided from the file type (never by loading the media on the main thread).
        player.frame = playerIsAudio ? CGRect(x: 12, y: preview.frame.maxY + 6, width: w - 24, height: 32) : preview.frame
        // Songs: the bar is the player. Videos: the bar sits over the bottom of the picture.
        controls.frame = playerIsAudio ? player.frame : CGRect(x: player.frame.minX + 8, y: player.frame.maxY - 38,
                                                               width: player.frame.width - 16, height: 30)
        updateTrackingAreas()
        updateControls()
        let ny = (controls.isHidden || !playerIsAudio ? preview.frame.maxY : controls.frame.maxY) + 10
        let nh = nameLabel.sizeThatFits(CGSize(width: w - 24, height: 200)).height
        nameLabel.frame = CGRect(x: 12, y: ny, width: w - 24, height: nh)
        grid.frame = CGRect(x: 12, y: nameLabel.frame.maxY + 12, width: w - 24, height: max(0, bounds.height - nameLabel.frame.maxY - 20))
        // Values wrap to the panel's current width (it can be resized after they were added).
        for case let row as NSStackView in grid.arrangedSubviews {
            if let v = row.arrangedSubviews.last as? NSTextField { v.preferredMaxLayoutWidth = valueWidth }
        }
    }

    private var valueWidth: CGFloat { max(80, bounds.width - 140) }

    // MARK: Player controls

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: player.frame, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseEntered(with event: NSEvent) { overVideo = true; updateControls() }
    override func mouseExited(with event: NSEvent) { overVideo = false; updateControls() }

    /// Songs always show the bar; videos while the pointer is over them or they're paused.
    private func updateControls() {
        let active = player.player != nil
        let show = active && (playerIsAudio || overVideo || !controls.isPlaying)
        guard controls.isHidden == show else { return }
        controls.isHidden = !show
        if !playerIsAudio {
            controls.alphaValue = show ? 0 : 1
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; controls.animator().alphaValue = show ? 1 : 0 }
        }
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let o = windowCloseObserver { NotificationCenter.default.removeObserver(o); windowCloseObserver = nil }
        guard let newWindow else { return }
        // Closing the window must silence the player even if the window controller lingers.
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow,
                                                                     queue: .main) { [weak self] _ in self?.stopPlayer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        // Hidden: stop playback. Panels are removed and re-added when the layout is rebuilt, so wait a turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil else { return }
            self.stopPlayer()
            self.shownURLs = []
            self.container = nil
        }
    }

    // MARK: Content

    /// Re-renders after a settings change: what to show may change too (hover on/off), and dates or the preview.
    /// A video or song that is still shown keeps playing.
    func refresh() {
        if let c = container, window != nil {
            shownURLs = []
            show(hovered: hoveredURL, container: c)
        } else if !shownURLs.isEmpty {
            update(shownURLs)
        }
        needsLayout = true
    }

    /// Shows the hovered item (if "Show item on hover"), else the selection, else the folder.
    func show(hovered: URL?, container c: ViewContainer) {
        container = c
        hoveredURL = Settings.shared.infoShowHovered ? hovered : nil
        let urls: [URL]
        if let h = hoveredURL { urls = [h] }
        else if !c.model.selection.isEmpty { urls = c.model.selectedItems.map(\.url) }
        else { urls = [c.url] }
        guard urls != shownURLs else { return }
        shownURLs = urls
        update(urls)
    }

    /// The item for a URL: read from disk for local files; remote items come from the view's listing.
    private func item(for u: URL) -> FileItem? {
        if u.isFileURL { return FileItem.load(u) }
        if let c = container {
            if let i = c.model.index(of: u), c.model.rows.indices.contains(i) { return c.model.rows[i].item }
            if u == c.url {
                // A remote or virtual folder itself.
                let name = PlacesModel.shared.title(for: u) ?? (RemoteFS.isRemote(u) ? RemoteFS.displayName(for: u) : u.lastPathComponent)
                return FileItem(url: u, name: name, isDirectory: true, contentType: "public.folder")
            }
        }
        return nil
    }

    private func update(_ urls: [URL]) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        observeThumbnail(nil)
        defer { needsLayout = true }
        if urls.count > 1 {
            stopPlayer()
            showSummary(of: urls)
            return
        }
        guard let u = urls.first, let item = item(for: u) else {
            stopPlayer()
            preview.image = nil
            nameLabel.stringValue = ""
            return
        }
        nameLabel.stringValue = PlacesModel.shared.title(for: u) ?? item.name
        showPreview(of: item)
        setupPlayer(for: item)
        addDetailRows(for: item)
    }

    private func showSummary(of urls: [URL]) {
        preview.image = Icons.shared.image("document-multiple", size: 128) ?? Icons.shared.image("folder", size: 128)
        nameLabel.stringValue = "\(urls.count) items selected"
        // The view already has the items (thousands may be selected; no need to read each from disk again).
        let wanted = Set(urls)
        var items = container?.model.selectedItems.filter { wanted.contains($0.url) } ?? []
        if items.count < urls.count {
            let known = Set(items.map(\.url))
            items += urls.filter { !known.contains($0) && $0.isFileURL }.compactMap(FileItem.load)
        }
        let files = items.filter { !$0.isBrowsableFolder }
        let folders = items.count - files.count
        if folders > 0 { addRow("Folders:", "\(folders)") }
        if !files.isEmpty { addRow("Files:", "\(files.count)") }
        addRow("Size:", FileFormat.size(files.reduce(Int64(0)) { $0 + $1.size }))
    }

    private func showPreview(of item: FileItem) {
        let big = Self.previewSize
        preview.image = Icons.shared.image(for: item, size: big)
        guard Settings.shared.infoShowPreview, Thumbnails.wantsPreview(item) else { return }
        if let t = Thumbnails.shared.thumbnail(for: item, size: big) { preview.image = t } else { observeThumbnail(item) }
    }

    /// Waits for the item's thumbnail. One observer at most: the previous one is removed on every update.
    private func observeThumbnail(_ item: FileItem?) {
        if let o = thumbnailObserver { NotificationCenter.default.removeObserver(o); thumbnailObserver = nil }
        guard let item else { return }
        // Thumbnails posts the URL as the object; URLs bridge to new objects, so compare by value.
        thumbnailObserver = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? URL) == item.url, self.shownURLs == [item.url] else { return }
            // Kept until the next update: a smaller size for the same file may arrive first.
            if let t = Thumbnails.shared.thumbnail(for: item, size: Self.previewSize) {
                self.preview.image = t
                // The video's poster too, if the player is already there (thumbnails can take a while).
                if self.poster.superview != nil { self.poster.image = t }
            }
        }
    }

    private func addDetailRows(for item: FileItem) {
        let u = item.url
        addRow("Type:", item.typeDescription)
        // Remote items: only what the listing knows (no local metadata to read).
        guard u.isFileURL else {
            if !item.isBrowsableFolder { addRow("Size:", FileFormat.size(item.size)) }
            if let d = item.modificationDate { addRow("Modified:", formatted(d)) }
            if !RemoteFS.isRemote(u) || item.isBrowsableFolder { addRow("Location:", u.absoluteString.removingPercentEncoding ?? u.absoluteString) }
            return
        }
        if item.isBrowsableFolder {
            if let n = DirectoryLister.childCount(u, includeHidden: false) { addRow("Contains:", FileFormat.itemCount(n)) }
        } else {
            addRow("Size:", FileFormat.size(item.size))
        }
        let date = formatted
        if let d = item.modificationDate { addRow("Modified:", date(d)) }
        if let d = item.creationDate { addRow("Created:", date(d)) }
        if let d = item.accessDate { addRow("Accessed:", date(d)) }
        addRow("Permissions:", FileFormat.permissions(item.posixPermissions, isDirectory: item.isDirectory))
        addRow("Owner:", item.owner ?? "")
        if let l = item.linkDestination { addRow("Link to:", l) }
        let tags = (try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        if !tags.isEmpty { addRow("Tags:", tags.joined(separator: ", ")) }
        for (k, v) in spotlightMetadata(item) { addRow(k, v) }
    }

    private func formatted(_ d: Date) -> String {
        Settings.shared.infoCondensedDates ? Self.condensed.string(from: d) : FileFormat.relativeDate(d)
    }

    /// Image/audio/video details from Spotlight (Baloo's role on KDE).
    private func spotlightMetadata(_ item: FileItem) -> [(String, String)] {
        let key = item.url.path + "|" + String(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)
        if let c = metadataCache[key] { return c }
        guard let md = MDItemCreateWithURL(nil, item.url as CFURL) else { return [] }
        var out: [(String, String)] = []
        func attr(_ k: CFString) -> Any? { MDItemCopyAttribute(md, k) }
        if let w = attr(kMDItemPixelWidth) as? Int, let h = attr(kMDItemPixelHeight) as? Int { out.append(("Dimensions:", "\(w) × \(h)")) }
        if let d = attr(kMDItemDurationSeconds) as? Double {
            let s = Int(d.rounded())
            out.append(("Duration:", s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                                : String(format: "%d:%02d", s / 60, s % 60)))
        }
        if let a = attr(kMDItemAuthors) as? [String], !a.isEmpty { out.append(("Artist:", a.joined(separator: ", "))) }
        if let al = attr(kMDItemAlbum) as? String { out.append(("Album:", al)) }
        if let p = attr(kMDItemNumberOfPages) as? Int { out.append(("Pages:", "\(p)")) }
        if let w = attr(kMDItemWhereFroms) as? [String], let f = w.first { out.append(("Downloaded From:", f)) }
        if metadataCache.count >= Self.metadataCacheLimit { metadataCache.removeAll() }
        metadataCache[key] = out
        return out
    }

    private func addRow(_ key: String, _ value: String) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        let k = NSTextField(labelWithString: key)
        k.font = Theme.font
        k.textColor = Theme.windowTextInactive
        k.alignment = .right
        k.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = Theme.font
        v.textColor = Theme.windowText
        v.isSelectable = true
        v.preferredMaxLayoutWidth = valueWidth
        row.addArrangedSubview(k)
        row.addArrangedSubview(v)
        grid.addArrangedSubview(row)
    }

    // MARK: Player

    /// For tests: "<scheme> <status> <seconds>" of the inline player.
    var playerDebug: String {
        guard let p = player.player else { return "none" }
        let u = (p.currentItem?.asset as? AVURLAsset)?.url
        return "\(u?.scheme ?? "-") \(p.currentItem?.status.rawValue ?? -1) \(String(format: "%.1f", p.currentTime().seconds)) poster=\(poster.superview != nil) \(p.currentItem?.error?.localizedDescription ?? "")"
    }

    /// Pauses and releases the player, cancels a pending start and stops the ffmpeg stream.
    private func stopPlayer() {
        playerWork?.cancel()
        playerWork = nil
        player.player?.pause()
        // Before releasing the player: the controls hold it weakly and must remove their time observer from it.
        controls.detach()
        player.player = nil
        player.isHidden = true
        controls.isHidden = true
        playObservation = nil
        playerURL = nil
        poster.removeFromSuperview()
        VideoPreview.shared.stop(for: self)
    }

    private func setupPlayer(for item: FileItem) {
        let playable = Settings.shared.infoShowPreview && item.url.isFileURL && (item.utType.map {
            $0.conforms(to: .audiovisualContent) || VideoPreview.isVideoExtension(item.fileExtension) } ?? false)
        // Re-rendering the same file (a settings change, the view reloading) keeps it playing.
        if playable, playerURL == item.url, player.player != nil || playerWork != nil { return }
        stopPlayer()
        guard playable, let t = item.utType else { return }
        playerIsAudio = t.conforms(to: .audio)
        player.isHidden = true
        let url = item.url
        playerURL = url
        let work = DispatchWorkItem { [weak self] in
            guard let owner = self else { return }
            VideoPreview.shared.playableURL(for: url, owner: owner) { [weak self] playable in
                guard let self, self.shownURLs == [url], let playable else { return }
                self.startPlayer(with: playable)
            }
        }
        playerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playerDelay, execute: work)
    }

    private func startPlayer(with playable: URL) {
        let p = AVPlayer(url: playable)
        p.automaticallyWaitsToMinimizeStalling = false
        player.player = p
        // Songs play without a picture: the bar is all there is.
        player.isHidden = playerIsAudio
        controls.attach(p, duration: playable.scheme == "http" ? VideoPreview.shared.streamDuration : nil)
        controls.onStateChange = { [weak self] in self?.updateControls() }
        needsLayout = true
        // The thumbnail stays over the video until it plays (with autoplay too: no black frame while it starts).
        if !playerIsAudio, let thumb = preview.image, let overlay = player.contentOverlayView {
            poster.image = thumb
            poster.frame = overlay.bounds
            poster.autoresizingMask = [.width, .height]
            overlay.addSubview(poster)
            playObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard player.timeControlStatus == .playing else { return }
                DispatchQueue.main.async { self?.poster.removeFromSuperview(); self?.playObservation = nil }
            }
        }
        guard playable.scheme == "http" else {
            if Settings.shared.infoAutoPlay { p.play() }
            return
        }
        // A live stream starts at its newest part; previews start at the beginning.
        Task { @MainActor [weak self] in
            for _ in 0..<100 where p.currentItem?.status != .readyToPlay { try? await Task.sleep(nanoseconds: 50_000_000) }
            // The panel may have moved on while the stream was starting.
            guard let self, self.player.player === p else { return }
            await p.seek(to: .zero)
            if Settings.shared.infoAutoPlay, self.player.player === p { p.play() }
        }
    }
}
