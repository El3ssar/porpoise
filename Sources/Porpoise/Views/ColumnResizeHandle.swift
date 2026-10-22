import AppKit

/// The handle at the foot of a Column view divider, as in Finder: drag it to resize the column on its left,
/// Option-drag to resize every column (and the width new ones open at), double-click it to fit the longest name.
final class ColumnResizeHandle: NSView {
    /// A new width for the column, from the drag; `all` with Option held.
    var onResize: ((_ width: CGFloat, _ all: Bool) -> Void)?
    var onFit: ((_ all: Bool) -> Void)?
    /// The column's width when the drag started.
    var columnWidth: () -> CGFloat = { 0 }
    var onDragEnded: (() -> Void)?

    static let width: CGFloat = 12
    static let gripHeight: CGFloat = 16

    private var dragStart: (x: CGFloat, width: CGFloat)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Column width")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The whole divider resizes; the grip at its foot shows where.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func draw(_ dirty: NSRect) {
        let grip = CGRect(x: bounds.midX - 3, y: bounds.maxY - Self.gripHeight - 4, width: 6, height: Self.gripHeight)
        Theme.viewBackground.setFill()
        NSBezierPath(roundedRect: grip.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()
        let lines = NSBezierPath()
        for x in [grip.midX - 1, grip.midX + 1] {
            lines.move(to: CGPoint(x: floor(x) + 0.5, y: grip.minY + 4))
            lines.line(to: CGPoint(x: floor(x) + 0.5, y: grip.maxY - 4))
        }
        NSColor.tertiaryLabelColor.setStroke()
        lines.lineWidth = 1
        lines.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onFit?(event.modifierFlags.contains(.option))
            return
        }
        dragStart = (event.locationInWindow.x, columnWidth())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onResize?(start.width + event.locationInWindow.x - start.x, event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnded?()
    }

    // VoiceOver: the splitter's value is the width; increment and decrement step it.
    override func accessibilityValue() -> Any? { NSNumber(value: Double(columnWidth())) }
    override func accessibilityPerformIncrement() -> Bool { onResize?(columnWidth() + 20, false); onDragEnded?(); return true }
    override func accessibilityPerformDecrement() -> Bool { onResize?(columnWidth() - 20, false); onDragEnded?(); return true }
}
