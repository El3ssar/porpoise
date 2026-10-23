import AppKit

/// Where the line between the two panes of a split tab goes: a share of the width, kept clear of the narrowest a pane
/// may be (QSplitter keeps views usable), whether the user drags it or the window gets narrower.
enum SplitLayout {
    /// Narrowest a pane can be.
    static let minPaneWidth: CGFloat = 160

    /// Ways the line can still move.
    enum Directions { case both, left, right }

    /// Lowest and highest x the line may have in `width`; nil when both minimums don't fit (the panes then share it).
    static func range(in width: CGFloat) -> ClosedRange<CGFloat>? {
        let lo = minPaneWidth, hi = width - minPaneWidth - SplitDividerView.lineWidth
        return lo <= hi ? lo...hi : nil
    }

    /// The line's x (the left pane's width) for `x` wanted in `width`: inside the range, else halves.
    static func clamped(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        guard let r = range(in: width) else { return ((width - SplitDividerView.lineWidth) / 2).rounded() }
        return min(max(x.rounded(), r.lowerBound), r.upperBound)
    }

    /// The line's x for `fraction` of `width`.
    static func lineX(fraction: CGFloat, in width: CGFloat) -> CGFloat { clamped(width * fraction, in: width) }

    static func directions(atX x: CGFloat, in width: CGFloat) -> Directions {
        guard let r = range(in: width), r.lowerBound < r.upperBound else { return .both }
        if x <= r.lowerBound { return .right }
        if x >= r.upperBound { return .left }
        return .both
    }
}

/// The line between the two panes, drawn like a thin NSSplitView divider (the window's hairline) with a wider
/// invisible grab area. Drag moves it, double-click resets it (Dolphin's splitter handle); the cursor shows which ways
/// it can go, as Finder's does. The line is a layer: moving the divider draws nothing.
final class SplitDividerView: NSView {
    static let lineWidth: CGFloat = 1
    /// Grab area on each side of the line (still clear of the overlay scroller's knob).
    static let grabMargin: CGFloat = 3
    static let width = lineWidth + 2 * grabMargin

    /// Drag: where the line should go, in window coordinates.
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// VoiceOver's increment (`right`) and decrement.
    var onStep: ((_ right: Bool) -> Void)?
    /// The left pane's share of the width, for VoiceOver.
    var share: () -> CGFloat = { 0.5 }
    /// Which ways the line can still be dragged (the tab sets it as the line moves).
    var directions = SplitLayout.Directions.both {
        didSet { if directions != oldValue { refreshCursor() } }
    }

    private let line = CALayer()
    /// Pointer offset from the line when the drag started, so the line doesn't jump under the pointer.
    private var grabOffset: CGFloat = 0
    private(set) var isDragging = false
    /// The press was a double-click: what follows until the release is not a drag.
    private var ignoresDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(line)
        Theme.whenChanged(self) { [weak self] in self?.line.backgroundColor = Theme.hairline.cgColor }
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Split view divider")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The line's color as shown (tests read it).
    var lineColor: CGColor? { line.backgroundColor }

    override var mouseDownCanMoveWindow: Bool { false }
    /// A background window's divider drags at once, like NSSplitView's.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        line.frame = CGRect(x: Self.grabMargin, y: 0, width: Self.lineWidth, height: bounds.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        line.frame = CGRect(x: Self.grabMargin, y: 0, width: Self.lineWidth, height: newSize.height)
    }

    // MARK: Cursor

    var cursor: NSCursor {
        switch directions {
        case .both: return .columnResize(directions: .all)
        case .left: return .columnResize(directions: .left)
        case .right: return .columnResize(directions: .right)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    /// While dragging, the cursor is held (the pointer leaves the line past a limit); else the cursor rect changes.
    private func refreshCursor() {
        if isDragging { cursor.set() } else { window?.invalidateCursorRects(for: self) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        ignoresDrag = event.clickCount >= 2
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        grabOffset = convert(event.locationInWindow, from: nil).x - Self.grabMargin
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoresDrag else { return }
        isDragging = true
        onDrag?(event.locationInWindow.x - grabOffset)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        ignoresDrag = false
        guard isDragging else { return }
        isDragging = false
        window?.invalidateCursorRects(for: self)
    }

    /// The line is no scroll view: scrolling on it scrolls the pane on the pointer's side.
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let beside = convert(CGPoint(x: p.x < bounds.midX ? -1 : bounds.width + 1, y: p.y), to: nil)
        // The window's frame view has no superview: it hit-tests in window coordinates.
        if let target = window?.contentView?.superview?.hitTest(beside), target !== self {
            target.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? { NSNumber(value: Double(share())) }
    override func accessibilityPerformIncrement() -> Bool { onStep?(true); return onStep != nil }
    override func accessibilityPerformDecrement() -> Bool { onStep?(false); return onStep != nil }
}
