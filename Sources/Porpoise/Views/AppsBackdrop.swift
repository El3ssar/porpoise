import AppKit
import PorpoiseCore
import PorpoiseServices

/// The library's background, made only from the theme's colours (so any theme recolours it): the view background
/// with a gentle wash of the window colour at the top and a soft glow of the selection colour for depth.
final class AppsBackdrop: NSView {
    private let wash = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let glow2 = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.viewBackground.cgColor
        wash.colors = [Theme.windowBackground.cgColor, Theme.viewBackground.cgColor]
        wash.locations = [0, 0.55]
        wash.startPoint = CGPoint(x: 0.5, y: 0)
        wash.endPoint = CGPoint(x: 0.5, y: 1)
        for (g, color, alpha) in [(glow, Theme.selection, 0.22), (glow2, Theme.activeText, 0.10)] {
            g.type = .radial
            g.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
        }
        for l in [wash, glow, glow2] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        // One glow behind the top of the grid, a fainter one low on the other side.
        let w = bounds.width, h = bounds.height
        glow.frame = CGRect(x: w * 0.05, y: -h * 0.25, width: w * 0.9, height: h * 0.9)
        glow2.frame = CGRect(x: w * 0.45, y: h * 0.45, width: w * 0.8, height: h * 0.8)
        CATransaction.commit()
    }
}
