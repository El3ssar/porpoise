import AppKit
import PorpoiseCore
import PorpoiseServices

/// Small/large icon glyph at the ends of the zoom slider (clickable: one step).
final class ZoomGlyph: NSView {
    let large: Bool
    var onClick: (() -> Void)?
    init(large: Bool) { self.large = large; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        let s: CGFloat = large ? 13 : 8
        let r = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        let p = NSBezierPath(roundedRect: r, xRadius: large ? 3 : 2, yRadius: large ? 3 : 2)
        Theme.windowText.withAlphaComponent(0.75).setStroke()
        p.lineWidth = 1.3
        p.stroke()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
