import AppKit
import PorpoiseCore
import PorpoiseServices

/// A capsule of toolbar controls: Liquid Glass on macOS 26+, a frosted material before that.
final class GlassGroup: NSView {
    let content = NSView()
    private var glass: NSView?

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
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        glass?.frame = bounds
        content.frame = bounds
    }
}
