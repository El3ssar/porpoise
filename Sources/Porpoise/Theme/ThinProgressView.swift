import AppKit

/// A thin progress track: how far work has got (`fraction`), or a band going across it while that isn't known
/// (`isIndeterminate`). With Reduce Motion the band stays still in the middle and the fill doesn't glide.
final class ThinProgressView: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsLayout = true; describe() } }
    }
    var isIndeterminate = false {
        didSet {
            guard isIndeterminate != oldValue else { return }
            fill.layer?.removeAnimation(forKey: Self.band)
            needsLayout = true
            describe()
        }
    }
    private static let band = "indeterminate"
    private let thickness: CGFloat
    private let trackColor: () -> NSColor
    private let fillColor: () -> NSColor
    private let track = NSView()
    private let fill = NSView()

    /// `thickness`: the track's height, centered in the view. The colors are read again when the theme changes.
    init(
        thickness: CGFloat = 4, label: String? = nil, track: @escaping () -> NSColor = { Theme.windowText.withAlphaComponent(0.14) },
        fill: @escaping () -> NSColor = { Theme.activeText }
    ) {
        self.thickness = thickness
        trackColor = track
        fillColor = fill
        super.init(frame: .zero)
        for v in [self.track, self.fill] {
            v.wantsLayer = true
            v.layer?.cornerRadius = thickness / 2
        }
        self.track.layer?.masksToBounds = true
        self.track.addSubview(self.fill)
        addSubview(self.track)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        if let label { setAccessibilityLabel(label) }
        describe()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.layer?.backgroundColor = trackColor().cgColor
            fill.layer?.backgroundColor = fillColor().cgColor
        }
        track.frame = CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        let width = track.bounds.width
        if isIndeterminate {
            let band = min(90, width * 0.3)
            fill.frame = CGRect(x: (width - band) / 2, y: 0, width: band, height: thickness)
            if Animator.reducesMotion() {
                fill.layer?.removeAnimation(forKey: Self.band)
            } else if fill.layer?.animation(forKey: Self.band) == nil {
                let animation = CABasicAnimation(keyPath: "position.x")
                animation.fromValue = -band / 2
                animation.toValue = width + band / 2
                animation.duration = Motion.indeterminate * Animator.timeScale
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fill.layer?.add(animation, forKey: Self.band)
            }
            return
        }
        fill.layer?.removeAnimation(forKey: Self.band)
        let target = CGRect(x: 0, y: 0, width: width * max(0, min(1, fraction)), height: thickness)
        if Animator.reducesMotion() || fill.frame == .zero {
            fill.frame = target
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.progress * Animator.timeScale
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fill.animator().frame = target
            }
        }
    }

    private func describe() {
        if isIndeterminate {
            setAccessibilityValue(nil)
            setAccessibilityValueDescription("In progress")
        } else {
            let percent = Int((max(0, min(1, fraction)) * 100).rounded())
            setAccessibilityValue(percent)
            setAccessibilityValueDescription("\(percent) percent")
        }
    }
}
