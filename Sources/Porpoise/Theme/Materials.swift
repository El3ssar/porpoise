import AppKit
import PorpoiseServices

/// A macOS material (vibrancy) tinted with a Desert color: the wallpaper glows through softly, like Finder's
/// sidebar and toolbar, while the colors stay those of the Desert-Dark scheme.
final class TintedMaterialView: NSVisualEffectView {
    private let tintLayer = CALayer()

    init(material: NSVisualEffectView.Material, tint: NSColor = Theme.windowBackground, alpha: CGFloat = 0.72,
         blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = blending
        state = .followsWindowActiveState
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        tintLayer.backgroundColor = tint.withAlphaComponent(alpha).cgColor
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

/// Small frosted "pill" used for floating overlays (status text, zoom slider).
final class PillMaterialView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension NSView {
    /// Soft drop shadow for floating elements.
    func applyFloatingShadow() {
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}

/// Simple per-frame animator (a 120 Hz timer in the common run loop modes, so it keeps running during
/// event tracking such as live resize), used for custom-drawn transitions.
final class Animator {
    private var timer: Timer?

    /// Runs `step(progress)` with progress eased 0→1 over `duration`, replacing any running animation
    /// (whose completion is then not called).
    func run(duration: TimeInterval, curve: @escaping (Double) -> Double = Animator.easeOutCubic,
             step: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        stop()
        // Reduce Motion (Accessibility › Display): jump to the end state.
        if duration <= 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { step(1); completion?(); return }
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            step(curve(p))
            guard p >= 1 else { return }
            t.invalidate()
            self?.timer = nil
            completion?()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { timer?.invalidate() }

    static func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    static func easeInCubic(_ p: Double) -> Double { p * p * p }
}
