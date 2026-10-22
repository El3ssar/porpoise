import AppKit
import PorpoiseServices

/// A macOS material (vibrancy) tinted with a theme color: the wallpaper glows through softly, like Finder's
/// sidebar and toolbar, while the colors stay those of the theme. The native theme leaves the material untinted, as
/// Finder does.
final class TintedMaterialView: NSVisualEffectView {
    private let tintLayer = CALayer()
    private let tint: NSColor
    private let tintAlpha: CGFloat
    private func updateTint() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        tintLayer.backgroundColor = tint.withAlphaComponent(Tokens.isNative ? 0 : opaque ? 1 : tintAlpha).cgColor
    }

    init(
        material: NSVisualEffectView.Material, tint: NSColor = Theme.windowBackground, alpha: CGFloat = 0.72,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.tint = tint; tintAlpha = alpha
        super.init(frame: .zero)
        self.material = material
        blendingMode = blending
        state = .followsWindowActiveState
        wantsLayer = true
        Theme.whenChanged(self) { [weak self] in self?.updateTint() }
        layer?.addSublayer(tintLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    /// Off for a background inside a control (the status bar): clicks pass through to the view that owns it
    /// instead of dragging the window.
    var movesWindow = true

    override var mouseDownCanMoveWindow: Bool { movesWindow }

    override func hitTest(_ point: NSPoint) -> NSView? { movesWindow ? super.hitTest(point) : nil }

    /// Clicks on bare material (toolbar/sidebar backgrounds) go to the window: drag to move.
    override func mouseDown(with event: NSEvent) {
        if let next = nextResponder as? NSView, next.mouseDownCanMoveWindow { next.mouseDown(with: event) } else { window?.performDrag(with: event) }
    }
}

/// Runs a custom-drawn transition: a progress from 0 to 1 over a duration, eased, one step per frame shown
/// (`FrameClock`).
final class Animator: NSObject {
    /// Reduce Motion (Accessibility › Display): everything that animates jumps to its end. The one switch for the
    /// app (tests set it, so a machine's own setting can't change what they see).
    nonisolated(unsafe) static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private let clock = FrameClock()
    private var completion: (() -> Void)?

    /// Runs `step(progress)` with progress eased 0→1 over `duration`, replacing any running animation
    /// (whose completion is then not called). Steps follow the display's refresh: one per frame shown.
    /// `showsEnd`: the completion waits for the next frame, so the end state is on screen before it runs. A slow machine
    /// skips frames, and the last one shown may be far from the end: what the completion puts in place (the items
    /// copies fly onto) would then seem to jump.
    func run(
        duration: TimeInterval, curve: @escaping (Double) -> Double = Animator.easeOutCubic, showsEnd: Bool = false,
        step: @escaping (Double) -> Void, completion: (() -> Void)? = nil
    ) {
        stop()
        self.completion = completion
        // The clock starts with the first frame: work done right after `run` (a new split pane being set up) would
        // otherwise use up part of the animation before anything is drawn, and it would seem to jump.
        var start: CFTimeInterval?
        var ended = false
        // Reduce Motion (Accessibility › Display), or nothing to show it on: jump to the end state.
        guard duration > 0, !Animator.reducesMotion(),
            clock.run({ [weak self] now in
                guard let self else { return false }
                if ended { return self.finish() }
                let begin = start ?? now
                start = begin
                let p = min(1, (now - begin) / duration)
                step(curve(p))
                guard p >= 1 else { return true }
                if showsEnd {
                    ended = true
                    return true
                }
                return self.finish()
            })
        else {
            self.completion = nil
            step(1)
            completion?()
            return
        }
    }

    /// Ends the clock and calls the completion; false, so the clock stops.
    private func finish() -> Bool {
        let done = completion
        stop()
        done?()
        return false
    }

    var isRunning: Bool { clock.isRunning }

    /// Fades `view` to `alpha`: at once with Reduce Motion.
    static func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval = Motion.fade) {
        guard !reducesMotion() else { view.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = duration
            view.animator().alphaValue = alpha
        }
    }

    /// Ends the animation where it is, without its completion.
    func stop() {
        clock.stop()
        completion = nil
    }

    static func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    static func easeInCubic(_ p: Double) -> Double { p * p * p }
    static func easeInOutCubic(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
}
