import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices

/// Space previews for uncached cloud media use AVPlayer because Quick Look requires a local file URL.
final class CloudMediaPreviewPanel: NSPanel, NSWindowDelegate {
    private let video = AVPlayerView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "Loading preview…")
    private var shown: String?
    private let playback = CloudPlaybackSession()
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

    func show(_ file: FileItem, provider: any CloudFileProvider, relativeTo parent: NSWindow) {
        title = file.name
        let key = file.url.absoluteString + "|" + String(file.modificationDate?.timeIntervalSince1970 ?? 0)
        if shown == key, isVisible { return }
        stop()
        shown = key
        spinner.frame = NSRect(x: video.bounds.midX - 10, y: video.bounds.midY, width: 20, height: 20)
        status.frame = NSRect(x: 20, y: video.bounds.midY - 40, width: video.bounds.width - 40, height: 30)
        status.stringValue = "Loading preview…"
        spinner.startAnimation(nil)
        if !isVisible { setFrameOrigin(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)) }
        makeKeyAndOrderFront(nil)
        playback.onPlayer = { [weak self] player, _ in
            self?.video.player = player; player.play()
        }
        playback.onStatus = { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading: self.spinner.startAnimation(nil); self.status.stringValue = "Loading preview…"
            case .buffering: self.spinner.startAnimation(nil); self.status.stringValue = "Buffering…"
            case .ready: self.spinner.stopAnimation(nil); self.status.stringValue = ""
            case .unavailable(let error, let opening):
                self.spinner.stopAnimation(nil); self.status.stringValue = opening ? "Preview unavailable" : "Playback unavailable"
                self.status.toolTip = error?.localizedDescription
            }
        }
        playback.start { try await provider.playback(file.url) }
    }

    private func stop() {
        shown = nil
        playback.stop(); video.player = nil
    }

    func windowWillClose(_ notification: Notification) { stop() }
}
