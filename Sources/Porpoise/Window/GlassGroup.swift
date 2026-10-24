import AppKit
import PorpoiseCore
import PorpoiseServices

/// A capsule of toolbar controls: Liquid Glass on macOS 26+, a frosted material before that.
final class GlassGroup: NSView {
    let content = NSView()
    private var glass: NSView?
    private let ring = Ring()
    /// The accent outline that marks this capsule as the current one: the active pane's location in a split.
    var showsCurrent = false { didSet { ring.isHidden = !showsCurrent } }
    /// The corner radius asked for; nil: a capsule (half the height), whatever height it is given.
    private let fixedRadius: CGFloat?

    init(cornerRadius: CGFloat? = nil) {
        fixedRadius = cornerRadius
        super.init(frame: .zero)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.contentView = content
            // Resolved again on every change of look or palette (a layer-backed tint keeps the colour it was given).
            Theme.whenChanged(self) { [weak g] in g?.tintColor = Theme.windowBackground.usingColorSpace(.sRGB)?.withAlphaComponent(0.35) }
            glass = g
            addSubview(g)
        } else {
            let v = NSVisualEffectView()
            v.material = .headerView
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.addSubview(content)
            glass = v
            addSubview(v)
        }
        ring.wantsLayer = true
        ring.isHidden = true
        ring.layer?.borderWidth = Ring.width
        ring.layer?.cornerCurve = .continuous
        addSubview(ring)
        Theme.whenChanged(ring) { [weak ring] in ring?.layer?.borderColor = Theme.accent.cgColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        glass?.frame = bounds
        content.frame = bounds
        ring.frame = bounds
        let radius = fixedRadius ?? bounds.height / 2
        ring.layer?.cornerRadius = radius
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = radius
        } else {
            glass?.layer?.cornerRadius = radius
        }
    }

    /// Drawn over the glass; clicks go through to what it surrounds.
    private final class Ring: NSView {
        /// As the location field's own ring while it's edited: a mark, lighter than the keyboard focus ring.
        static let width: CGFloat = 1.5
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
