import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices

/// Space previews for uncached cloud media use AVPlayer because Quick Look requires a local file URL.
final class DriveMediaPreviewPanel: NSPanel, NSWindowDelegate {
    private let video = AVPlayerView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "Loading preview…")
    private var shown: String?
    private var loading: Task<Void, Never>?
    private var stream: DriveStreamingPreview?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    var onArrow: ((NSEvent) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        delegate = self
        video.controlsStyle = .floating
        video.autoresizingMask = [.width, .height]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        video.frame = content.bounds
        content.addSubview(video)
        contentView = content
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        content.addSubview(status)
        status.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        center()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 49 { close(); return }
        if [123, 124, 125, 126].contains(event.keyCode) { onArrow?(event); return }
        super.keyDown(with: event)
    }

    func show(_ file: DriveFile, client: DriveClient, relativeTo parent: NSWindow) {
        title = file.name
        let key = "\(client.accountID)|\(file.id)|\(file.headRevisionId ?? file.version ?? "")"
        if shown == key, isVisible { return }
        stop()
        shown = key
        spinner.frame = NSRect(x: video.bounds.midX - 10, y: video.bounds.midY, width: 20, height: 20)
        status.frame = NSRect(x: 20, y: video.bounds.midY - 40, width: video.bounds.width - 40, height: 30)
        status.stringValue = "Loading preview…"
        spinner.startAnimation(nil)
        if !isVisible { setFrameOrigin(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)) }
        makeKeyAndOrderFront(nil)
        loading = Task { @MainActor [weak self] in
            do {
                let cached = try await client.cachedPreview(file)
                try Task.checkCancellation()
                guard let self else { return }
                let url: URL
                if let cached {
                    url = cached
                } else {
                    let stream = try client.streamingPreview(file)
                    self.stream = stream; url = stream.url
                }
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 2
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = false
                self.video.player = player
                self.observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                    DispatchQueue.main.async {
                        guard let self, self.video.player === player else { return }
                        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            self.spinner.startAnimation(nil); self.status.stringValue = "Buffering…"
                        } else {
                            self.spinner.stopAnimation(nil); self.status.stringValue = ""
                        }
                    }
                }
                self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    DispatchQueue.main.async {
                        guard let self, self.video.player?.currentItem === item else { return }
                        self.spinner.stopAnimation(nil)
                        self.status.stringValue = "Playback unavailable"
                        self.status.toolTip = item.error?.localizedDescription
                    }
                }
                player.play()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.spinner.stopAnimation(nil); self.status.stringValue = "Preview unavailable"
                self.status.toolTip = error.localizedDescription
            }
        }
    }

    private func stop() {
        shown = nil
        loading?.cancel(); loading = nil
        observation = nil; itemObservation = nil
        video.player?.pause(); video.player = nil
        stream?.stop(); stream = nil
    }

    func windowWillClose(_ notification: Notification) { stop() }
    deinit { loading?.cancel(); stream?.stop() }
}
