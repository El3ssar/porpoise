import AVFoundation
import AppKit
import PorpoiseServices

/// Porpoise's own playback controls for the Information panel: play/pause, a time bar and the times. AVKit's
/// built-in controls crash on macOS 26+ for streams still being converted (their length isn't known yet), so the
/// player view shows no controls of its own and this bar drives the AVPlayer instead, for every format.
final class MediaControls: NSView {
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    /// The real length when the item doesn't know it yet (a stream that is still being converted).
    private var knownDuration: Double?
    private var dragging = false
    /// Playing started or stopped (the panel shows or hides the bar).
    var onStateChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.windowBackground.withAlphaComponent(0.82).cgColor
        appearance = NSAppearance(named: .darkAqua)
        playButton.isBordered = false
        playButton.imageScaling = .scaleProportionallyDown
        playButton.contentTintColor = Theme.windowText
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.setAccessibilityLabel("Play")
        slider.minValue = 0
        slider.maxValue = 1
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(scrub(_:))
        slider.setAccessibilityLabel("Playback Position")
        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = Theme.windowTextInactive
        }
        total.alignment = .right
        [playButton, elapsed, slider, total].forEach(addSubview)
        updatePlayIcon(playing: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { detach() }

    override func layout() {
        super.layout()
        let h = bounds.height, mid = h / 2
        playButton.frame = CGRect(x: 6, y: mid - 12, width: 24, height: 24)
        let lw: CGFloat = 46
        elapsed.frame = CGRect(x: 32, y: mid - 7, width: lw, height: 14)
        total.frame = CGRect(x: bounds.width - lw - 8, y: mid - 7, width: lw, height: 14)
        slider.frame = CGRect(x: elapsed.frame.maxX + 2, y: mid - 9, width: max(20, total.frame.minX - elapsed.frame.maxX - 6), height: 18)
    }

    // MARK: Player

    func attach(_ p: AVPlayer, duration: Double?) {
        detach()
        player = p
        knownDuration = duration
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.refreshTime()
        }
        statusObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async {
                self?.updatePlayIcon(playing: playing); self?.onStateChange?()
            }
        }
        refreshTime()
    }

    func detach() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        statusObservation = nil
        player = nil
        knownDuration = nil
        onStateChange = nil
        slider.doubleValue = 0
        elapsed.stringValue = "0:00"
        total.stringValue = "0:00"
        updatePlayIcon(playing: false)
    }

    var isPlaying: Bool { player.map { $0.timeControlStatus != .paused } ?? false }

    @objc func togglePlay() {
        guard let p = player else { return }
        if p.timeControlStatus == .paused {
            // At the end: start over.
            if let d = duration, p.currentTime().seconds >= d - 0.25 { p.seek(to: .zero) }
            p.play()
        } else {
            p.pause()
        }
    }

    /// The length: the item's own, or the one known from the file while a stream is still being converted.
    private var duration: Double? {
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return knownDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private func refreshTime() {
        guard let p = player else { return }
        let now = max(0, p.currentTime().seconds.isFinite ? p.currentTime().seconds : 0)
        elapsed.stringValue = Self.format(now)
        if let d = duration {
            total.stringValue = Self.format(d)
            if !dragging { slider.doubleValue = min(1, now / d) }
            slider.isEnabled = true
        } else {
            total.stringValue = "--:--"
            slider.isEnabled = false
        }
    }

    @objc private func scrub(_ s: NSSlider) {
        guard let p = player, let d = duration else { return }
        dragging = NSApp.currentEvent?.type == .leftMouseDragged
        var target = s.doubleValue * d
        // A stream that is still being converted can only go as far as what's ready.
        if let end = p.currentItem?.seekableTimeRanges.last?.timeRangeValue.end.seconds, end.isFinite, end > 0, target > end {
            target = max(0, end - 1)
        }
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed.stringValue = Self.format(target)
        if NSApp.currentEvent?.type == .leftMouseUp { dragging = false }
    }

    private func updatePlayIcon(playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: playing ? "Pause" : "Play")
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
