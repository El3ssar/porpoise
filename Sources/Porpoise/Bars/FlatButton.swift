import AppKit
import PorpoiseCore
import PorpoiseServices

/// Flat Breeze-style tool button (icon, optional text), with hover and pressed backgrounds.
class FlatButton: NSControl {
    var iconName: String? { didSet { needsDisplay = true } }
    var title: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Off: icon only (the title stays the accessibility label), for bars short of room.
    var showsTitle = true { didSet { if showsTitle != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private var shownTitle: String { showsTitle || iconName == nil ? title : "" }
    var isToggled = false { didSet { needsDisplay = true; setAccessibilityValue(isToggled ? 1 : 0) } }
    var showsMenuIndicator = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var iconSize: CGFloat = 16
    var cornerRadius: CGFloat = 4
    var menuProvider: (() -> NSMenu?)?
    /// Split button: clicking the right part opens the menu, the left part performs the action.
    var isSplitButton = false
    var onClick: (() -> Void)?
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?
    private var longPressTimer: Timer?
    private var menuOpenedByLongPress = false

    /// Width of the arrow part of a split button.
    private static let splitArrowWidth: CGFloat = 18
    /// Width taken by KDE's small "has menu" corner arrow.
    private static let cornerArrowWidth: CGFloat = 6
    /// KDE's delayed popup: holding a button with a menu opens it.
    private static let longPressDelay: TimeInterval = 0.45

    convenience init(icon: String?, title: String = "", tooltip: String? = nil, action: (() -> Void)? = nil) {
        self.init(frame: .zero)
        iconName = icon
        self.title = title
        toolTip = tooltip
        onClick = action
        setAccessibilityRole(.button)
        // "Up (⌘↑)" reads as "Up": VoiceOver announces the shortcut by itself.
        let label = title.isEmpty ? (tooltip ?? "") : title
        setAccessibilityLabel(label.range(of: " (").map { String(label[..<$0.lowerBound]) } ?? label)
    }

    // MARK: Keyboard and VoiceOver

    /// Reachable with Tab when Full Keyboard Access is on (System Settings › Keyboard), as standard buttons are.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill() }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": perform()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { perform(); return true }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let m = menuProvider?() else { return false }
        popUpMenu(m)
        return true
    }

    private func perform() {
        onClick?()
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    override var isFlipped: Bool { true }
    /// Buttons in the title bar must not start window drags.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width(showingTitle: showsTitle), height: 30) }

    /// Width the button needs with or without its title.
    func width(showingTitle: Bool) -> CGFloat {
        var w: CGFloat = iconName != nil ? iconSize + 12 : 12
        let title = showingTitle || iconName == nil ? title : ""
        if !title.isEmpty { w += (title as NSString).size(withAttributes: [.font: Theme.font]).width + (iconName != nil ? 6 : 0) }
        w += menuIndicatorWidth
        return ceil(w)
    }

    private var menuIndicatorWidth: CGFloat {
        showsMenuIndicator ? (isSplitButton ? Self.splitArrowWidth : Self.cornerArrowWidth) : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        let onMenuPart = isSplitButton && p.x > bounds.width - Self.splitArrowWidth
        // Plain menu buttons and the arrow part of split buttons open the menu at once.
        if menuProvider != nil, !isSplitButton || onMenuPart, onClick == nil || onMenuPart, let m = menuProvider?() {
            popUpMenu(m)
            return
        }
        pressing = true
        menuOpenedByLongPress = false
        needsDisplay = true
        // Long press on buttons with a menu (Back/Forward history) opens the menu.
        if menuProvider != nil {
            longPressTimer?.invalidate()
            let t = Timer(timeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
                guard let self, self.pressing, let m = self.menuProvider?() else { return }
                self.menuOpenedByLongPress = true
                self.pressing = false
                self.popUpMenu(m)
            }
            RunLoop.current.add(t, forMode: .common)
            longPressTimer = t
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressing && !menuOpenedByLongPress { pressing = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        let wasPressing = pressing
        pressing = false
        needsDisplay = true
        guard wasPressing, !menuOpenedByLongPress, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }

    private func popUpMenu(_ m: NSMenu) {
        pressing = true
        needsDisplay = true
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 4), in: self)
        pressing = false
        hovering = false
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { m.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 4), in: self) }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isEnabled && (hovering || pressing || isToggled) {
            let p = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
            (pressing || isToggled ? Theme.buttonPressedBackground : Theme.buttonHoverBackground).setFill()
            p.fill()
            if isToggled {
                Theme.focus.withAlphaComponent(0.7).setStroke()
                p.lineWidth = 1
                p.stroke()
            }
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        let title = shownTitle
        var x: CGFloat = 6
        let menuW = menuIndicatorWidth
        let contentW = intrinsicContentSize.width - 12 - menuW
        if title.isEmpty || iconName == nil { x = (bounds.width - menuW - contentW) / 2 }
        if let name = iconName, let img = Icons.shared.image(name, size: iconSize) {
            img.draw(in: CGRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize), from: .zero,
                     operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x += iconSize + 6
        }
        if !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.windowText.withAlphaComponent(alpha)]
            let s = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: CGPoint(x: x, y: (bounds.height - s.height) / 2), withAttributes: attrs)
        }
        if showsMenuIndicator {
            if isSplitButton {
                Icons.shared.image("go-down", size: 16)?.draw(in: CGRect(x: bounds.width - 17, y: (bounds.height - 16) / 2, width: 16, height: 16),
                                                              from: .zero, operation: .sourceOver, fraction: alpha * 0.9, respectFlipped: true, hints: nil)
            } else {
                // KDE's small "has menu" arrow at the bottom right (Back/Forward).
                let p = NSBezierPath()
                let bx = bounds.width - 7, by = bounds.height - 6
                p.move(to: CGPoint(x: bx - 2.5, y: by - 1.5)); p.line(to: CGPoint(x: bx, y: by + 1)); p.line(to: CGPoint(x: bx + 2.5, y: by - 1.5))
                Theme.windowText.withAlphaComponent(0.7 * alpha).setStroke()
                p.lineWidth = 1
                p.stroke()
            }
        }
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
}
