import AppKit
import PorpoiseCore
import PorpoiseServices

/// Small/large icon glyph at the ends of the zoom slider (clickable: one step). A button for VoiceOver, and with Full
/// Keyboard Access one Tab stop (Space or Return steps).
final class ZoomGlyph: NSView {
    let large: Bool
    var onClick: (() -> Void)?
    init(large: Bool) {
        self.large = large
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(large ? "Larger Icons" : "Smaller Icons")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { KeyboardAccess.isFull() }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(Int(event.keyCode)) { onClick?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
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
