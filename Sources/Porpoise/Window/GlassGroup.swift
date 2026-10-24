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

    init(cornerRadius: CGFloat = 17) {
        super.init(frame: .zero)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.tintColor = Theme.windowBackground.withAlphaComponent(0.35)
            g.contentView = content
            glass = g
            addSubview(g)
        } else {
            let v = NSVisualEffectView()
            v.material = .headerView
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
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
        ring.layer?.cornerRadius = bounds.height / 2
    }

    /// Drawn over the glass; clicks go through to what it surrounds.
    private final class Ring: NSView {
        /// As the location field's own ring while it's edited: a mark, lighter than the keyboard focus ring.
        static let width: CGFloat = 1.5
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
