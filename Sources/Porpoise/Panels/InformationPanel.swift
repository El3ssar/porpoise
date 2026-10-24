import AVKit
import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import QuickLookThumbnailing

/// Dolphin's Information panel (F10 here): large preview, name and metadata of the hovered item, the selection,
/// or the current folder.
final class InformationPanel: NSView {
    private let preview = PreviewImageView()
    let codePreview = CodePreviewView(frame: .zero)
    private var codeCleanup: URL?
    private let previewSpinner = NSProgressIndicator()
    private let previewStatus = NSTextField(wrappingLabelWithString: "")
    private var playbackSession: CloudPlaybackSession?
    private var drivePreview: Task<Void, Never>?
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let grid = NSStackView()
    /// Inspector look: same tinted material as the sidebar.
    private let material = TintedMaterialView(material: .sidebar, tint: Theme.panelBackground, alpha: 0.72)
    /// Off where the panel sits inside the file view (Column view's preview column): the view's own background shows.
    var showsMaterial = true { didSet { material.isHidden = !showsMaterial } }
    /// Dolphin's information panel plays audio/video inline. The view shows no controls of its own (see MediaControls).
    private let player = AVPlayerView()
    private let controls = MediaControls()
    /// The pointer is over the video (its controls show while it is, and whenever it's paused).
    private var overVideo = false
    private var hoverArea: NSTrackingArea?

    private var shownURLs: [URL] = []
    /// The size and date of the one item shown, as listed: a listing that says otherwise (a download growing, an
    /// image edited) shows it again.
    private var shownStamp: (size: Int64, date: Date?)?
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
    /// A stream's readiness, until it's ready or failed.
    private var streamObservation: NSKeyValueObservation?
    private var playerWork: DispatchWorkItem?
    private var thumbnailObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var listingObserver: NSObjectProtocol?
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

    /// A stop in the window's Tab order, so the keyboard (and VoiceOver's cursor) can get to what it shows.
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.insetBy(dx: 2, dy: 2).fill() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Information")
        listingObserver = NotificationCenter.default.addObserver(forName: ViewContainer.listingReloaded, object: nil, queue: .main) {
            [weak self] n in
            if let c = n.object as? ViewContainer { self?.listingReloaded(in: c) }
        }
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .small
        previewSpinner.isDisplayedWhenStopped = false
        preview.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = Tokens.font(.title3, scaled: true)
        nameLabel.textColor = Theme.windowText
        nameLabel.alignment = .center
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        addSubview(material)
        player.controlsStyle = .none
        player.isHidden = true
        player.wantsLayer = true
        player.layer?.cornerRadius = Tokens.Radius.medium
        player.layer?.masksToBounds = true
        // Clicking the video plays or pauses it.
        player.addGestureRecognizer(NSClickGestureRecognizer(target: controls, action: #selector(MediaControls.togglePlay)))
        controls.isHidden = true
        codePreview.isHidden = true
        [preview, codePreview, player, controls, nameLabel, grid].forEach(addSubview)
        addSubview(previewSpinner)
        previewStatus.font = Tokens.font(.caption, weight: .regular)
        previewStatus.textColor = Theme.windowTextInactive
        previewStatus.alignment = .center
        addSubview(previewStatus)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        [thumbnailObserver, windowCloseObserver, listingObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        playerWork?.cancel()
        drivePreview?.cancel()
        if let codeCleanup { try? FileManager.default.removeItem(at: codeCleanup) }
    }

    override func draw(_ dirty: NSRect) {}

    override func layout() {
        super.layout()
        material.frame = bounds
        let w = bounds.width
        let side = min(w - 40, Self.maxPreviewSide)
        preview.frame = CGRect(x: (w - side) / 2, y: 16, width: side, height: Settings.shared.infoShowPreview ? side : 0)
        codePreview.frame = CGRect(x: 12, y: preview.frame.minY, width: max(0, w - 24), height: preview.frame.height)
        // Decided from the file type (never by loading the media on the main thread).
        previewSpinner.frame = CGRect(x: preview.frame.midX - 8, y: preview.frame.midY - 8, width: 16, height: 16)
        previewStatus.frame = CGRect(x: preview.frame.minX, y: preview.frame.maxY - 26, width: preview.frame.width, height: 24)
        player.frame = playerIsAudio ? CGRect(x: 12, y: preview.frame.maxY + 6, width: w - 24, height: 32) : preview.frame
        // Songs: the bar is the player. Videos: the bar sits over the bottom of the picture.
        controls.frame =
            playerIsAudio
            ? player.frame
            : CGRect(
                x: player.frame.minX + 8, y: player.frame.maxY - 38,
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
            Animator.fade(controls, to: show ? 1 : 0)
        }
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let o = windowCloseObserver { NotificationCenter.default.removeObserver(o); windowCloseObserver = nil }
        guard let newWindow else { return }
        // Closing the window must silence the player even if the window controller lingers.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: newWindow,
            queue: .main
        ) { [weak self] _ in
            self?.stopPlayer()
            self?.drivePreview?.cancel()
            self?.clearCodePreview()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        // Hidden: stop playback. Panels are removed and re-added when the layout is rebuilt, so wait a turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil else { return }
            self.stopPlayer()
            self.clearCodePreview()
            self.drivePreview?.cancel(); self.drivePreview = nil
            self.previewSpinner.stopAnimation(nil)
            self.shownURLs = []
            self.container = nil
        }
    }

    // MARK: Content

    /// Re-renders after a settings change: what to show may change too (hover on/off), and dates or the preview.
    /// A video or song that is still shown keeps playing.
    func refresh() {
        // A change of Settings › font size reaches an open panel: the name's font too (the rows are made again).
        nameLabel.font = Tokens.font(.title3, scaled: true)
        if let c = container, window != nil {
            shownURLs = []
            show(hovered: hoveredURL, container: c)
        } else if !shownURLs.isEmpty {
            update(shownURLs)
        }
        needsLayout = true
    }

    /// The container's folder was listed again: the item shown is read again if it changed since.
    func listingReloaded(in c: ViewContainer) {
        guard c === container, shownURLs.count == 1, let u = shownURLs.first, let stamp = shownStamp,
            let i = c.model.index(of: u), c.model.rows.indices.contains(i)
        else { return }
        let listed = c.model.rows[i].item
        guard listed.size != stamp.size || listed.modificationDate != stamp.date else { return }
        update(shownURLs)
    }

    /// Shows the hovered item (if "Show item on hover"), else the selection, else the folder.
    func show(hovered: URL?, container c: ViewContainer) {
        container = c
        hoveredURL = Settings.shared.infoShowHovered ? hovered : nil
        let urls: [URL]
        if let h = hoveredURL { urls = [h] } else if !c.model.selection.isEmpty { urls = c.model.selectedItems.map(\.url) } else { urls = [c.url] }
        hoverWork?.cancel()
        guard urls != shownURLs else { return }
        // Moving across rows: only the row the pointer rests on is read (each reads the disk and Spotlight).
        guard hoveredURL != nil else {
            shownURLs = urls
            update(urls)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownURLs != urls else { return }
            self.shownURLs = urls
            self.update(urls)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    private var hoverWork: DispatchWorkItem?
    /// How long the pointer rests on a row before the panel shows it.
    private static let hoverDelay: TimeInterval = 0.08

    /// A remote or virtual item, from the view's listing.
    private func item(for u: URL) -> FileItem? {
        if let c = container {
            if let i = c.model.index(of: u), c.model.rows.indices.contains(i) { return c.model.rows[i].item }
            if u == c.url {
                // A remote or virtual folder itself.
                let name = LocationNaming.title(for: u)
                return FileItem(url: u, name: name, isDirectory: true, contentType: "public.folder")
            }
        }
        return nil
    }

    private func update(_ urls: [URL]) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        observeThumbnail(nil)
        clearCodePreview()
        defer { needsLayout = true }
        if urls.count > 1 {
            stopPlayer()
            showSummary(of: urls)
            return
        }
        detailWork?.cancel()
        guard let u = urls.first else { return clear() }
        guard u.isFileURL else {
            // Remote and virtual items: what the view's listing knows, no disk to read.
            guard let item = item(for: u) else { return clear() }
            show(item, details: nil)
            return
        }
        // This Mac (or a mounted share): the item as listed shows at once; reading it again, counting a folder's
        // items, its permissions, tags and Spotlight's details happen off the main thread, and land only if it's
        // still the item shown (a big folder or a slow share never stalls the window, nor do rows rushed past).
        let listed = container.flatMap { c in c.model.index(of: u).flatMap { c.model.rows.indices.contains($0) ? c.model.rows[$0].item : nil } }
        if let listed { show(listed, details: nil) }
        let cached = metadataCache
        // Only the latest read lands: one begun before the item changed (and shown again) would put back what it was.
        detailGeneration &+= 1
        let generation = detailGeneration
        let work = DispatchWorkItem { [weak self] in
            let read = Self.readDetails(of: u, spotlight: cached)
            DispatchQueue.main.async {
                guard let self, self.shownURLs == urls, self.detailGeneration == generation else { return }
                guard let read else { return self.clear() }
                self.metadataCache[read.spotlightKey] = read.spotlight
                if self.metadataCache.count >= Self.metadataCacheLimit { self.metadataCache.removeAll() }
                self.show(read.item, details: read, keepsPreview: listed?.url == read.item.url)
            }
        }
        detailWork = work
        Self.detailQueue(for: u).async(execute: work)
    }

    /// Nothing to show.
    private func clear() {
        stopPlayer()
        drivePreview?.cancel(); drivePreview = nil
        previewStatus.stringValue = ""
        previewSpinner.stopAnimation(nil)
        preview.image = nil
        preview.isPicture = false
        nameLabel.stringValue = ""
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    /// `item`'s name, preview and details (`details`: what was read from disk; nil: what the item itself knows).
    /// `keepsPreview`: it already shows (from the listing), the picture or player isn't set up again.
    private func show(_ item: FileItem, details: Details?, keepsPreview: Bool = false) {
        shownStamp = (item.size, item.modificationDate)
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        nameLabel.stringValue = PlacesModel.shared.title(for: item.url) ?? item.name
        if !keepsPreview {
            showPreview(of: item)
            setupPlayer(for: item)
        }
        addDetailRows(for: item, details: details)
        needsLayout = true
    }

    private var detailWork: DispatchWorkItem?
    private var detailGeneration: UInt64 = 0
    /// Disk and Spotlight reads for the panel, one at a time per volume; a newer selection cancels those not started.
    /// One queue per volume: a read stuck on a share whose server went away holds only that share's items, never the
    /// panel for everything else.
    private static var detailQueues: [String: DispatchQueue] = [:]

    static func detailQueue(for url: URL) -> DispatchQueue {
        let volume = MountTable.mountPoint(of: url.standardizedFileURL.path) ?? "/"
        if let q = detailQueues[volume] { return q }
        let q = DispatchQueue(label: "porpoise.information \(volume)", qos: .userInitiated)
        detailQueues[volume] = q
        return q
    }

    /// What the panel reads from disk about one local item, off the main thread.
    struct Details {
        let item: FileItem
        let childCount: Int?
        let permissions: String
        let tags: [String]
        let spotlight: [(String, String)]
        let spotlightKey: String
    }

    /// Reads it (nil: the item is gone). `spotlight`: details already read, by item and date.
    nonisolated static func readDetails(of u: URL, spotlight cache: [String: [(String, String)]]) -> Details? {
        // A new URL: one already asked keeps the resource values it read then (a grown file would show its old size).
        guard let item = FileItem.load(URL(fileURLWithPath: u.path, isDirectory: u.hasDirectoryPath)) else { return nil }
        let key = item.url.path + "|" + String(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)
        return Details(
            item: item,
            childCount: item.isBrowsableFolder ? DirectoryLister.childCount(u, includeHidden: false) : nil,
            permissions: AccessSummary.text(forFileAt: u.path),
            tags: (try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [],
            spotlight: cache[key] ?? spotlightMetadata(item),
            spotlightKey: key)
    }

    private func showSummary(of urls: [URL]) {
        drivePreview?.cancel(); drivePreview = nil
        previewStatus.stringValue = ""
        previewSpinner.stopAnimation(nil)
        preview.image = Icons.shared.image("document-multiple", size: 128) ?? Icons.shared.image("folder", size: 128)
        preview.isPicture = false
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

    private func showPreview(of item: FileItem, allowsCode: Bool = true) {
        drivePreview?.cancel(); drivePreview = nil
        previewStatus.stringValue = ""
        previewSpinner.stopAnimation(nil)
        let big = Self.previewSize
        preview.image = Icons.shared.image(for: item, size: big)
        preview.isPicture = false
        // Text thumbnail preferences stay unchanged. The explicit Information preview has its own switch.
        let settings = Settings.shared
        let withinSizeLimit = settings.previewMaxSizeMiB <= 0 || item.size <= Int64(settings.previewMaxSizeMiB) * 1024 * 1024
        let remoteText = settings.previewRemote && (SyntaxLanguage.detect(filename: item.name) != nil || item.utType?.conforms(to: .text) == true)
        if allowsCode, settings.infoShowPreview, withinSizeLimit, CodePreviewView.supports(item), item.url.isFileURL || remoteText {
            showCodePreview(item)
            return
        }
        guard Settings.shared.infoShowPreview, Thumbnails.wantsPreview(item) else { return }
        // A cloud file's large preview arrives in steps; a video's or a song's is its thumbnail, cached like any other.
        if PreviewSource.isProgressive(item.url), item.utType?.conforms(to: .audiovisualContent) != true {
            previewSpinner.startAnimation(nil)
            previewStatus.stringValue = "Loading preview…"
            drivePreview = Task { @MainActor [weak self] in
                do {
                    let paint: (URL) async throws -> Void = { [weak self] local in
                        try Task.checkCancellation()
                        let image: NSImage?
                        if let loaded = NSImage(contentsOf: local) {
                            image = loaded
                        } else {
                            let request = QLThumbnailGenerator.Request(
                                fileAt: local, size: CGSize(width: big, height: big), scale: 2, representationTypes: .thumbnail)
                            image = await withCheckedContinuation { continuation in
                                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                                    continuation.resume(returning: rep?.nsImage)
                                }
                            }
                        }
                        guard !Task.isCancelled, let self, self.shownURLs == [item.url] else { return }
                        if let image {
                            self.preview.image = local.pathExtension == "pdf" ? Thumbnails.paperPreview(image) : image
                            self.preview.isPicture = true
                        }
                    }
                    let context = CloudTransferContext(progress: { [weak self] bytes, total in
                        Task { @MainActor in
                            guard let self, self.shownURLs == [item.url] else { return }
                            self.previewStatus.stringValue = total > 0 ? "Loading \(min(100, bytes * 100 / total))%" : "Loading preview…"
                        }
                    })
                    try await PreviewSource.progressive(item.url, context: context, onPreview: paint)
                    guard !Task.isCancelled, let self, self.shownURLs == [item.url] else { return }
                    self.previewSpinner.stopAnimation(nil); self.previewStatus.stringValue = ""
                } catch {
                    guard !Task.isCancelled, let self, self.shownURLs == [item.url] else { return }
                    self.previewSpinner.stopAnimation(nil); self.previewStatus.stringValue = "Preview unavailable"
                    self.previewStatus.toolTip = error.localizedDescription
                }
            }
            return
        }
        if let t = Thumbnails.shared.thumbnail(for: item, size: big) {
            preview.image = t
            preview.isPicture = true
        } else {
            observeThumbnail(item)
        }
    }

    private func clearCodePreview() {
        codePreview.cancel()
        codePreview.onCompletion = nil
        codePreview.isHidden = true
        preview.isHidden = false
        if let codeCleanup { try? FileManager.default.removeItem(at: codeCleanup) }
        codeCleanup = nil
    }

    private func showCodePreview(_ item: FileItem) {
        codePreview.onCompletion = { [weak self] success in
            guard !success, let self, self.shownURLs == [item.url] else { return }
            self.clearCodePreview()
            self.showPreview(of: item, allowsCode: false)
        }
        codePreview.isHidden = false
        preview.isHidden = true
        if item.url.isFileURL { codePreview.load(item.url, filename: item.name); return }
        drivePreview = Task { @MainActor [weak self] in
            do {
                if item.url.scheme == "archive" {
                    let local = try await ArchiveBrowser.localCopy(item.url)
                    guard let self, !Task.isCancelled, self.shownURLs == [item.url] else { return }
                    self.codePreview.load(local, filename: item.name)
                } else if PreviewSource.isProgressive(item.url) {
                    try await PreviewSource.progressive(item.url, context: .init()) { [weak self] local in
                        guard let self, !Task.isCancelled, self.shownURLs == [item.url] else { throw CancellationError() }
                        self.codePreview.load(local, filename: item.name)
                    }
                } else {
                    let local = try await PreviewSource.localFile(for: item.url, thumbnail: false)
                    guard let self, !Task.isCancelled, self.shownURLs == [item.url] else {
                        if let cleanup = local.cleanup { try? FileManager.default.removeItem(at: cleanup) }
                        return
                    }
                    self.codeCleanup = local.cleanup
                    self.codePreview.load(local.file, filename: item.name)
                }
            } catch {
                guard let self, !Task.isCancelled, self.shownURLs == [item.url] else { return }
                self.clearCodePreview()
                self.previewStatus.stringValue = "Preview unavailable"
            }
        }
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
                self.preview.isPicture = true
                // The video's poster too, if the player is already there (thumbnails can take a while).
                if self.poster.superview != nil { self.poster.image = t }
            }
        }
    }

    private func addDetailRows(for item: FileItem, details: Details?) {
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
            if let n = details?.childCount { addRow("Contains:", FileFormat.itemCount(n)) }
        } else {
            addRow("Size:", FileFormat.size(item.size))
        }
        let date = formatted
        if let d = item.modificationDate { addRow("Modified:", date(d)) }
        if let d = item.creationDate { addRow("Created:", date(d)) }
        if let d = item.accessDate { addRow("Accessed:", date(d)) }
        // In words, like Finder; the mode bits stay in Properties › Permissions and the Details column.
        // Read off the main thread: until then, what the listing knows.
        guard let details else { return }
        addRow("Permissions:", details.permissions)
        addRow("Owner:", item.owner ?? "")
        if let l = item.linkDestination { addRow("Link to:", l) }
        if !details.tags.isEmpty { addRow("Tags:", details.tags.joined(separator: ", ")) }
        for (k, v) in details.spotlight { addRow(k, v) }
    }

    private func formatted(_ d: Date) -> String {
        Settings.shared.infoCondensedDates ? Self.condensed.string(from: d) : FileFormat.relativeDate(d)
    }

    /// Image/audio/video details from Spotlight (Baloo's role on KDE).
    nonisolated private static func spotlightMetadata(_ item: FileItem) -> [(String, String)] {
        guard let md = MDItemCreateWithURL(nil, item.url as CFURL) else { return [] }
        var out: [(String, String)] = []
        func attr(_ k: CFString) -> Any? { MDItemCopyAttribute(md, k) }
        if let w = attr(kMDItemPixelWidth) as? Int, let h = attr(kMDItemPixelHeight) as? Int { out.append(("Dimensions:", "\(w) × \(h)")) }
        if let d = attr(kMDItemDurationSeconds) as? Double {
            let s = Int(d.rounded())
            out.append(
                (
                    "Duration:",
                    s >= 3600
                        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                        : String(format: "%d:%02d", s / 60, s % 60)
                ))
        }
        if let a = attr(kMDItemAuthors) as? [String], !a.isEmpty { out.append(("Artist:", a.joined(separator: ", "))) }
        if let al = attr(kMDItemAlbum) as? String { out.append(("Album:", al)) }
        if let p = attr(kMDItemNumberOfPages) as? Int { out.append(("Pages:", "\(p)")) }
        if let w = attr(kMDItemWhereFroms) as? [String], let f = w.first { out.append(("Downloaded From:", f)) }
        return out
    }

    private func addRow(_ key: String, _ value: String) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        let k = NSTextField(labelWithString: key)
        k.font = Tokens.font(.body, scaled: true)
        k.textColor = Theme.windowTextInactive
        k.alignment = .right
        k.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = Tokens.font(.body, scaled: true)
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
        return
            "\(u?.scheme ?? "-") \(p.currentItem?.status.rawValue ?? -1) \(String(format: "%.1f", p.currentTime().seconds)) poster=\(poster.superview != nil) \(p.currentItem?.error?.localizedDescription ?? "")"
    }

    /// Pauses and releases the player, cancels a pending start and stops the ffmpeg stream.
    private func stopPlayer() {
        playerWork?.cancel()
        playerWork = nil
        playbackSession?.stop(); playbackSession = nil
        player.player?.pause()
        // Before releasing the player: the controls hold it weakly and must remove their time observer from it.
        controls.detach()
        player.player = nil
        player.isHidden = true
        controls.isHidden = true
        playObservation = nil
        streamObservation = nil
        playerURL = nil
        poster.removeFromSuperview()
        VideoPreview.shared.stop(for: self)
    }

    private func setupPlayer(for item: FileItem) {
        let playable =
            Settings.shared.infoShowPreview
            && (item.url.isFileURL
                || (Settings.shared.previewRemote && Settings.shared.previewVideos && RemoteFS.provider(for: item.url) is CloudFileProvider))
            && (item.utType.map {
                $0.conforms(to: .audiovisualContent) || VideoPreview.isVideoExtension(item.fileExtension)
            } ?? false)
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
            if let cloud = RemoteFS.provider(for: url) as? CloudFileProvider {
                let session = CloudPlaybackSession(preferredForwardBufferDuration: 0, observesCached: false)
                owner.playbackSession = session
                session.onPlayer = { [weak owner] player, playable in
                    guard let owner, owner.shownURLs == [url] else { return }
                    owner.startPlayer(with: playable, player: player, cloud: true)
                }
                session.onStatus = { [weak owner] status in
                    guard let owner, owner.shownURLs == [url] else { return }
                    switch status {
                    case .loading: break
                    case .buffering: owner.previewSpinner.startAnimation(nil); owner.previewStatus.stringValue = "Buffering…"
                    case .ready: owner.previewSpinner.stopAnimation(nil); owner.previewStatus.stringValue = ""
                    case .unavailable(let error, _):
                        owner.previewSpinner.stopAnimation(nil); owner.previewStatus.stringValue = "Playback unavailable"
                        owner.previewStatus.toolTip = error?.localizedDescription
                    }
                }
                session.start { try await cloud.playback(url) }
                return
            }
            VideoPreview.shared.playableURL(for: url, owner: owner) { [weak self] playable in
                guard let self, self.shownURLs == [url], let playable else { return }
                self.startPlayer(with: playable)
            }
        }
        playerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playerDelay, execute: work)
    }

    private func startPlayer(with playable: URL, player supplied: AVPlayer? = nil, cloud: Bool = false) {
        let p = supplied ?? AVPlayer(url: playable)
        p.automaticallyWaitsToMinimizeStalling = false
        player.player = p
        // Songs play without a picture: the bar is all there is.
        player.isHidden = playerIsAudio
        controls.attach(p, duration: playable.scheme == "http" && !cloud ? VideoPreview.shared.streamDuration : nil)
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
                DispatchQueue.main.async {
                    self?.poster.removeFromSuperview(); self?.playObservation = nil
                }
            }
        }
        guard playable.scheme == "http", !cloud else {
            if Settings.shared.infoAutoPlay { p.play() }
            return
        }
        // A live stream starts at its newest part; previews start at the beginning: once it's ready (told, not polled
        // for), and never for one that failed to start.
        guard let item = p.currentItem else { return }
        streamObservation = Self.whenSettled(item) { [weak self] ready in
            guard let self, self.player.player === p else { return }
            self.streamObservation = nil
            guard ready else { return }
            Task { @MainActor [weak self] in
                await p.seek(to: .zero)
                // The panel may have moved on while it was seeking.
                if Settings.shared.infoAutoPlay, self?.player.player === p { p.play() }
            }
        }
    }

    /// Calls `done` on the main thread once `item` is ready (true) or has failed (false); keep the result while waiting.
    static func whenSettled(_ item: AVPlayerItem, _ done: @escaping (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status
            guard status != .unknown else { return }
            DispatchQueue.main.async { done(status == .readyToPlay) }
        }
    }
}
