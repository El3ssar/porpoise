import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

/// An app-owned material shell. Public Quick Look content stays inset and cannot replace the glass root.
final class SpacePreviewPanel: NSPanel, NSWindowDelegate, MaterialBackedWindow {
    let material = TintedMaterialView(material: .hudWindow)
    let code = CodePreviewView(frame: .zero)
    private let body = NSView()
    private var quickLook: QLPreviewView?
    private let video = AVPlayerView()
    private let folderIcon = NSImageView()
    private let playback = CloudPlaybackSession()
    private let status = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let openWith = NSButton(title: "Open With", target: nil, action: nil)
    private let share = NSButton(
        image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: nil, action: nil)
    private let fullScreen = NSButton(
        image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")!, target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var cleanup: URL?
    private var generation = UUID()
    private var items: [FileItem] = []
    private(set) var itemIndex = 0
    private(set) var state = "empty"
    private let zoom = Animator(name: "preview.open")
    private var zoomTarget: NSRect?
    var onArrow: ((NSEvent) -> Void)?
    var onOpenWith: ((FileItem, URL) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        collectionBehavior = [.fullScreenPrimary]
        minSize = NSSize(width: 560, height: 360)
        delegate = self
        contentView = material
        material.state = .active
        material.addSubview(body)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        indexLabel.alignment = .center
        indexLabel.textColor = .secondaryLabelColor
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        [heading, indexLabel, previous, next, openWith, share, fullScreen].forEach(material.addSubview)
        [code, video, folderIcon, status].forEach(body.addSubview)
        folderIcon.imageScaling = .scaleProportionallyDown
        folderIcon.setAccessibilityLabel("Folder preview")
        folderIcon.isHidden = true
        video.controlsStyle = .floating
        code.isHidden = true; video.isHidden = true
        for (button, action) in [
            (previous, #selector(previousItem)), (next, #selector(nextItem)), (openWith, #selector(showOpenWith)),
            (share, #selector(shareItem)), (fullScreen, #selector(enterFullScreen)),
        ] {
            button.target = self; button.action = action; button.bezelStyle = .texturedRounded
        }
        previous.setAccessibilityLabel("Previous selected item")
        next.setAccessibilityLabel("Next selected item")
        code.onCompletion = { [weak self] success in
            guard let self else { return }
            self.state = success ? "code" : "quicklook"
            if !success, let url = self.currentLocal { self.showQuickLook(url) }
        }
        Theme.whenChanged(self) { [weak self] in
            self?.backgroundColor = .clear
            self?.heading.textColor = Theme.windowText
        }
    }

    private var currentLocal: URL?
    required init?(coder: NSCoder) { fatalError() }
    deinit { task?.cancel() }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutContent()
    }

    private func layoutContent() {
        let r = material.bounds
        body.frame = NSRect(x: 18, y: 18, width: max(0, r.width - 36), height: max(0, r.height - 86))
        for view in body.subviews { view.frame = body.bounds }
        status.frame = NSRect(x: 12, y: body.bounds.midY - 14, width: max(0, body.bounds.width - 24), height: 28)
        let y = r.height - 61
        previous.frame = NSRect(x: 18, y: y, width: 28, height: 26)
        indexLabel.frame = NSRect(x: 48, y: y + 4, width: 66, height: 18)
        next.frame = NSRect(x: 116, y: y, width: 28, height: 26)
        heading.frame = NSRect(x: 156, y: y + 4, width: max(0, r.width - 388), height: 20)
        openWith.frame = NSRect(x: r.width - 220, y: y, width: 104, height: 26)
        share.frame = NSRect(x: r.width - 106, y: y, width: 38, height: 26)
        fullScreen.frame = NSRect(x: r.width - 58, y: y, width: 38, height: 26)
    }

    func windowDidResize(_ notification: Notification) { layoutContent() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 53 || event.keyCode == 49 { close(); return }
            if [123, 124, 125, 126].contains(event.keyCode) { onArrow?(event); return }
        }
        super.sendEvent(event)
    }

    func show(_ items: [FileItem], relativeTo parent: NSWindow, source: NSRect = .zero) {
        guard !items.isEmpty else { close(); return }
        let changed = self.items.map(\.url) != items.map(\.url)
        let old = self.items[safe: itemIndex]
        self.items = items
        if changed { itemIndex = 0 }
        let current = items[safe: itemIndex]
        let modified = old?.modificationDate != current?.modificationDate || old?.size != current?.size
        if changed || modified || state == "empty" { loadCurrent() }
        if !isVisible {
            let target = NSRect(
                x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2, width: frame.width, height: frame.height)
            let animated = !source.isEmpty && !Animator.reducesMotion()
            let scale = animated ? max(source.width / target.width, source.height / target.height) : 1
            let start =
                animated
                ? NSRect(
                    x: source.midX - target.width * scale / 2, y: source.midY - target.height * scale / 2,
                    width: target.width * scale, height: target.height * scale) : target
            zoomTarget = animated ? target : nil
            setFrame(start, display: false)
            alphaValue = animated ? 0 : 1
            makeKeyAndOrderFront(nil)
            if animated {
                zoom.run(
                    duration: 0.16,
                    step: { [weak self] p in
                        self?.setFrame(
                            NSRect(
                                x: start.minX + (target.minX - start.minX) * p,
                                y: start.minY + (target.minY - start.minY) * p,
                                width: start.width + (target.width - start.width) * p,
                                height: start.height + (target.height - start.height) * p), display: true)
                        self?.alphaValue = p
                    },
                    completion: { [weak self] in
                        self?.alphaValue = 1; self?.zoomTarget = nil
                    })
            }
        }
        layoutContent()
    }

    @objc private func previousItem() { move(-1) }
    @objc private func nextItem() { move(1) }
    func move(_ delta: Int) {
        let index = min(max(0, itemIndex + delta), max(0, items.count - 1))
        guard index != itemIndex else { return }
        itemIndex = index; loadCurrent()
    }

    private func clearContent() {
        generation = UUID()
        task?.cancel(); task = nil
        code.cancel(); code.isHidden = true
        playback.stop(); video.player = nil; video.isHidden = true
        folderIcon.image = nil; folderIcon.isHidden = true
        quickLook?.previewItem = nil; quickLook?.close(); quickLook?.removeFromSuperview(); quickLook = nil
        currentLocal = nil
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
        cleanup = nil
    }

    private func loadCurrent() {
        clearContent()
        guard let item = items[safe: itemIndex] else { return }
        title = item.name; heading.stringValue = item.name
        indexLabel.stringValue = "\(itemIndex + 1) of \(items.count)"
        previous.isEnabled = itemIndex > 0; next.isEnabled = itemIndex + 1 < items.count
        share.isEnabled = SharingPreparation.supports([item.url])
        openWith.isEnabled = item.url.isFileURL || !item.isDirectory
        status.stringValue = "Loading preview…"; status.isHidden = false
        state = "loading"
        let id = generation
        // A folder preview must not recursively download/extract its children just to show an icon.
        if item.isDirectory, !item.url.isFileURL {
            folderIcon.image = Icons.shared.image("folder", size: 128)
            folderIcon.isHidden = false; status.isHidden = true; state = "folder"
            return
        }
        if let cloud = RemoteFS.provider(for: item.url) as? CloudFileProvider, item.utType?.conforms(to: .audiovisualContent) == true {
            video.isHidden = false
            playback.onPlayer = { [weak self] player, _ in
                guard let self, self.generation == id else { return }
                self.video.player = player; player.play()
            }
            playback.onStatus = { [weak self] state in
                guard let self, self.generation == id else { return }
                switch state {
                case .loading: self.status.stringValue = "Loading preview…"
                case .buffering: self.status.stringValue = "Buffering…"
                case .ready: self.status.stringValue = ""; self.state = "media"
                case .unavailable: self.status.stringValue = "Playback unavailable"; self.state = "unavailable"
                }
            }
            playback.start { try await cloud.playback(item.url) }
            return
        }
        if item.url.isFileURL { present(item.url, item: item); return }
        task = Task { @MainActor [weak self] in
            do {
                if item.url.scheme == "archive" {
                    let local = try await ArchiveBrowser.localCopy(item.url)
                    try Task.checkCancellation()
                    guard let self, self.generation == id else { return }
                    self.present(local, item: item)
                } else if PreviewSource.isProgressive(item.url) {
                    try await PreviewSource.progressive(item.url, context: .init()) { [weak self] local in
                        try Task.checkCancellation()
                        guard let self, self.generation == id else { return }
                        self.present(local, item: item)
                    }
                } else {
                    let local = try await PreviewSource.localFile(for: item.url, thumbnail: false)
                    guard let self, !Task.isCancelled, self.generation == id else {
                        if let cleanup = local.cleanup { try? FileManager.default.removeItem(at: cleanup) }
                        return
                    }
                    self.cleanup = local.cleanup
                    self.present(local.file, item: item)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.status.stringValue = "Preview unavailable"; self.state = "unavailable"
            }
        }
    }

    private func present(_ local: URL, item: FileItem) {
        currentLocal = local
        status.isHidden = true
        if CodePreviewView.supports(item) {
            quickLook?.isHidden = true
            code.isHidden = false
            code.load(local, filename: item.name, materializeDataless: true)
        } else {
            showQuickLook(local)
        }
    }

    private func showQuickLook(_ local: URL) {
        code.isHidden = true
        if quickLook == nil {
            guard let view = QLPreviewView(frame: body.bounds, style: .normal) else {
                status.isHidden = false; status.stringValue = "Preview unavailable"; state = "unavailable"
                return
            }
            view.shouldCloseWithWindow = false
            view.autoresizingMask = [.width, .height]
            body.addSubview(view, positioned: .below, relativeTo: status)
            quickLook = view
        }
        quickLook?.isHidden = false
        quickLook?.previewItem = local as NSURL
        state = "quicklook"  // Public API exposes assignment, not a ready callback.
    }

    @objc private func enterFullScreen() { toggleFullScreen(nil) }
    @objc private func shareItem() {
        guard let item = items[safe: itemIndex] else { return }
        SharingCoordinator.shared.share([item.url], mode: .picker, from: share)
    }
    @objc private func showOpenWith() {
        guard let item = items[safe: itemIndex] else { return }
        let menu = NSMenu()
        let applications = item.utType.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        for app in applications.prefix(20) {
            let entry = NSMenuItem(title: MainWindowController.appName(app), action: #selector(openInApplication(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = app
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Other Application…", action: #selector(chooseApplication), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: openWith)
    }
    @objc private func chooseApplication() {
        guard let item = items[safe: itemIndex] else { return }
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.application]
        chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        chooser.prompt = "Open"
        chooser.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let app = chooser.url else { return }
            self?.onOpenWith?(item, app)
        }
    }

    @objc private func openInApplication(_ sender: NSMenuItem) {
        guard let item = items[safe: itemIndex], let app = sender.representedObject as? URL else { return }
        onOpenWith?(item, app)
    }

    func windowWillClose(_ notification: Notification) {
        zoom.stop(); alphaValue = 1
        if let zoomTarget { setFrame(zoomTarget, display: false) }
        zoomTarget = nil
        clearContent(); items = []; state = "empty"
    }
}
