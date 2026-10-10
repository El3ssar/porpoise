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
    var isToggled = false { didSet { needsDisplay = true } }
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
        setAccessibilityLabel(tooltip ?? title)
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
        onClick?()
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
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

// MARK: - Status bar

/// Dolphin's status bar. Full width (default here): a thin translucent strip with folder/selection info on the left,
/// the icon-size slider and a disk-space bar on the right. Small mode: Dolphin's floating box in the view's corner.
final class StatusBarView: NSView {
    var text = "" { didSet { if text != oldValue { update() } } }
    /// A message shown for a moment instead of `text` (see `showMessage`).
    var temporaryText: String? { didSet { if temporaryText != oldValue { update() } } }
    var progress: Double? { didSet { if (progress == nil) != (oldValue == nil) { updateSpinner() }; update() } }
    var freeSpaceText = "" { didSet { if freeSpaceText != oldValue { needsLayout = true; canvas.needsDisplay = true } } }
    var usedFraction: Double = 0 { didSet { if usedFraction != oldValue { canvas.needsDisplay = true } } }
    /// Continuous zoom level (0…16) shown by the slider.
    var zoomLevel: Double = 4 { didSet { if abs(slider.doubleValue - zoomLevel) > 0.001 { slider.doubleValue = zoomLevel } } }
    var onZoom: ((Double) -> Void)?
    var onZoomCommit: (() -> Void)?
    var onDiskClick: (() -> Void)?
    var mode: StatusBarMode = .fullWidth { didSet { update(); updateChrome() } }

    private let material = TintedMaterialView(material: .titlebar, alpha: 0.82, blending: .withinWindow)
    private let hairline = NSView()
    private let slider = NSSlider(value: 4, minValue: 0, maxValue: 16, target: nil, action: nil)
    private let small = ZoomGlyph(large: false)
    private let large = ZoomGlyph(large: true)
    private let spinner = NSProgressIndicator()
    /// Text and the disk bar are drawn here, above the material.
    private let canvas = StatusCanvas()
    private var tempTimer: Timer?
    /// Free-space text plus bar (clickable); `.zero` when hidden.
    private var diskRect: CGRect = .zero

    static let height: CGFloat = 28
    private static let diskBarWidth: CGFloat = 72
    private static let sliderWidth: CGFloat = 96
    private static let messageDuration: TimeInterval = 2.5
    private static let diskFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.appearance = NSAppearance(named: .darkAqua)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        small.onClick = { [weak self] in self?.stepZoom(-1) }
        large.onClick = { [weak self] in self?.stepZoom(1) }
        canvas.owner = self
        // Clicks on the bar reach it (disk bar → Storage settings) rather than dragging the window.
        material.movesWindow = false
        for v in [material, canvas, hairline, spinner, small, slider, large] as [NSView] { addSubview(v) }
        setAccessibilityRole(.staticText)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateChrome() {
        let full = mode == .fullWidth
        material.isHidden = !full
        hairline.isHidden = !full
        wantsSlider = full && Settings.shared.showZoomSlider
        needsLayout = true
    }

    /// The zoom slider is on (full-width mode and the setting); layout shows it when there is room.
    private var wantsSlider = false
    /// Room the folder/selection text keeps before the slider and then the disk bar give way in a narrow view.
    private static let minTextWidth: CGFloat = 110
    /// Small glyph, slider and large glyph.
    private static let sliderGroupWidth: CGFloat = 18 + sliderWidth + 4 + 16

    private func updateSpinner() {
        if progress != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func sliderMoved() {
        onZoom?(slider.doubleValue)
        slider.toolTip = "Icon size: \(Int(ZoomLevels.size(forContinuousLevel: slider.doubleValue))) pt"
        if let e = NSApp.currentEvent, e.type == .leftMouseUp { onZoomCommit?() }
    }

    private func stepZoom(_ d: Int) {
        let s = ZoomLevels.step(from: ZoomLevels.size(forContinuousLevel: slider.doubleValue), by: d)
        slider.doubleValue = ZoomLevels.continuousLevel(for: s)
        onZoom?(slider.doubleValue)
        onZoomCommit?()
    }

    func showMessage(_ s: String) {
        temporaryText = s
        tempTimer?.invalidate()
        tempTimer = Timer.scheduledTimer(withTimeInterval: Self.messageDuration, repeats: false) { [weak self] _ in self?.temporaryText = nil }
    }

    var displayText: String { temporaryText ?? text }

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowText.withAlphaComponent(0.88), .paragraphStyle: p]
    }

    /// Width the floating small bar needs.
    var smallWidth: CGFloat {
        let w = (displayText as NSString).size(withAttributes: [.font: Theme.font]).width + 18
        return progress != nil ? max(w, 180) : w
    }

    private func update() {
        setAccessibilityValue(displayText)
        superview?.needsLayout = true
        needsDisplay = true
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        canvas.frame = bounds
        canvas.needsDisplay = true
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let cy = bounds.height / 2
        spinner.frame = CGRect(x: 10, y: cy - 8, width: 16, height: 16)
        // Right side: [disk text + bar] [gap] [small glyph · slider · large glyph]. In a narrow view the disk bar,
        // then the slider, give way so the text stays readable and nothing is pushed out of the bar.
        var right = bounds.width - 12
        let oldDiskRect = diskRect
        defer { if diskRect != oldDiskRect { window?.invalidateCursorRects(for: self) } }
        let textMin = 12 + Self.minTextWidth + 16
        let sliderW = wantsSlider ? Self.sliderGroupWidth : 0
        let diskW = freeSpaceText.isEmpty ? 0
            : (freeSpaceText as NSString).size(withAttributes: [.font: Self.diskFont]).width + 8 + Self.diskBarWidth + 18
        let showsDisk = diskW > 0 && textMin + sliderW + diskW <= right
        let showsSlider = wantsSlider && textMin + sliderW <= right
        slider.isHidden = !showsSlider
        small.isHidden = !showsSlider
        large.isHidden = !showsSlider
        if showsDisk {
            let w = diskW - 18
            diskRect = CGRect(x: right - w, y: 0, width: w, height: bounds.height)
            right = diskRect.minX - 18
        } else {
            diskRect = .zero
        }
        if showsSlider {
            large.frame = CGRect(x: right - 16, y: cy - 8, width: 16, height: 16)
            slider.frame = CGRect(x: large.frame.minX - 4 - Self.sliderWidth, y: cy - 8, width: Self.sliderWidth, height: 16)
            small.frame = CGRect(x: slider.frame.minX - 18, y: cy - 8, width: 16, height: 16)
        }
    }

    private var leftContentEnd: CGFloat {
        if !slider.isHidden { return small.frame.minX - 16 }
        if diskRect != .zero { return diskRect.minX - 16 }
        return bounds.width - 12
    }

    override func draw(_ dirty: NSRect) {}

    fileprivate func drawContent() {
        let r = bounds
        if mode == .small {
            if displayText.isEmpty && progress == nil { return }
            // Dolphin's small status bar: a box flush with the view's bottom-left corner.
            let box = CGRect(x: -6, y: 0.5, width: r.width + 5.5, height: r.height + 6)
            let p = NSBezierPath(roundedRect: box, xRadius: Theme.frameRadius, yRadius: Theme.frameRadius)
            Theme.windowBackground.setFill(); p.fill()
            Theme.frame.setStroke(); p.lineWidth = 1; p.stroke()
            let s = (displayText as NSString).size(withAttributes: [.font: Theme.font])
            (displayText as NSString).draw(in: CGRect(x: 8, y: (r.height - s.height) / 2, width: r.width - 16, height: s.height + 2),
                                           withAttributes: [.font: Theme.font, .foregroundColor: Theme.windowText])
            return
        }
        let attrs = textAttrs
        let s = (displayText as NSString).size(withAttributes: attrs)
        let tx: CGFloat = progress != nil ? 32 : 12
        (displayText as NSString).draw(in: CGRect(x: tx, y: (r.height - s.height) / 2, width: max(0, leftContentEnd - tx), height: s.height + 2),
                                       withAttributes: attrs)
        if diskRect != .zero { drawDisk() }
    }

    /// "786 GiB free" + a slim capsule showing used space (blue → amber → red as the disk fills).
    private func drawDisk() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.diskFont, .foregroundColor: Theme.windowTextInactive.withAlphaComponent(0.85)]
        let ts = (freeSpaceText as NSString).size(withAttributes: attrs)
        let cy = bounds.height / 2
        (freeSpaceText as NSString).draw(at: CGPoint(x: diskRect.minX, y: cy - ts.height / 2), withAttributes: attrs)
        let bar = CGRect(x: diskRect.maxX - Self.diskBarWidth, y: cy - 3, width: Self.diskBarWidth, height: 6)
        let track = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
        Theme.windowText.withAlphaComponent(0.13).setFill()
        track.fill()
        let used = max(0.04, min(1, usedFraction))
        let fillRect = CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(used), height: bar.height)
        let colors: [NSColor] = used > 0.9 ? [Theme.neutralText.mixed(with: .systemOrange, 0.6), Theme.negativeText]
            : (used > 0.75 ? [Theme.selectionAlternate, .systemOrange] : [Theme.selection.lighter(150), Theme.selectionAlternate])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).addClip()
        NSGradient(colors: colors)?.draw(in: fillRect, angle: 0)
        // Soft top highlight for a little depth.
        NSColor.white.withAlphaComponent(0.18).setFill()
        CGRect(x: fillRect.minX, y: fillRect.minY, width: fillRect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if diskRect.contains(p) { onDiskClick?() }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if diskRect != .zero { addCursorRect(diskRect, cursor: .pointingHand) }
    }
}

/// Drawing surface of the status bar (sits above its material).
final class StatusCanvas: NSView {
    weak var owner: StatusBarView?
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) { owner?.drawContent() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Filter bar

protocol FilterBarDelegate: AnyObject {
    func filterBar(_ bar: FilterBar, changed filter: NameFilter)
    func filterBarClosed(_ bar: FilterBar)
}

/// Dolphin's filter bar (Ctrl+I / "/"): lock, text, mode, match case, close.
final class FilterBar: NSView, NSSearchFieldDelegate {
    weak var delegate: FilterBarDelegate?
    let field = NSSearchField()
    private let lockButton = FlatButton(icon: "object-unlocked", tooltip: "Keep Filter When Changing Folders")
    private let modeButton = FlatButton(icon: nil, title: FilterMode.plainText.title)
    private let caseButton = FlatButton(icon: "format-text-case", tooltip: "Match Case") // falls back to text
    private let closeButton = FlatButton(icon: "dialog-close", tooltip: "Hide Filter Bar")
    private let invalidLabel = NSTextField(labelWithString: "Invalid expression")
    var isLocked = false { didSet { lockButton.iconName = isLocked ? "object-locked" : "object-unlocked"; lockButton.isToggled = isLocked } }
    private(set) var filter = NameFilter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Filter…"
        field.font = Theme.font
        field.delegate = self
        field.sendsSearchStringImmediately = true
        // The field's clear (x) button changes the text without a text-did-change notification; its action catches it.
        field.target = self
        field.action = #selector(fieldAction)
        field.focusRingType = .none
        field.appearance = NSAppearance(named: .darkAqua)
        lockButton.onClick = { [weak self] in self?.isLocked.toggle() }
        modeButton.showsMenuIndicator = true
        modeButton.isSplitButton = true
        modeButton.menuProvider = { [weak self] in self?.modeMenu() }
        if !IconTheme.shared.has("format-text-case") { caseButton.iconName = nil; caseButton.title = "Aa" }
        caseButton.onClick = { [weak self] in
            guard let self else { return }
            self.caseButton.isToggled.toggle()
            self.filter.caseSensitive = self.caseButton.isToggled
            self.notify()
        }
        closeButton.onClick = { [weak self] in self.map { $0.delegate?.filterBarClosed($0) } }
        invalidLabel.textColor = Theme.negativeText
        invalidLabel.font = Theme.font
        invalidLabel.isHidden = true
        for v in [lockButton, field, invalidLabel, modeButton, caseButton, closeButton] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        lockButton.frame = CGRect(x: 6, y: (h - 28) / 2, width: 28, height: 28)
        closeButton.frame = CGRect(x: bounds.width - 34, y: (h - 28) / 2, width: 28, height: 28)
        caseButton.frame = CGRect(x: closeButton.frame.minX - 34, y: (h - 28) / 2, width: 30, height: 28)
        let mw = modeButton.intrinsicContentSize.width
        modeButton.frame = CGRect(x: caseButton.frame.minX - mw - 6, y: (h - 28) / 2, width: mw, height: 28)
        let iw: CGFloat = invalidLabel.isHidden ? 0 : 130
        invalidLabel.frame = CGRect(x: modeButton.frame.minX - iw - 4, y: (h - 18) / 2, width: iw, height: 18)
        field.frame = CGRect(x: 40, y: (h - 24) / 2, width: modeButton.frame.minX - 46 - iw, height: 24)
    }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        let l = NSBezierPath(); l.move(to: CGPoint(x: 0, y: 0.5)); l.line(to: CGPoint(x: bounds.width, y: 0.5))
        Theme.separator.setStroke(); l.stroke()
    }

    private func modeMenu() -> NSMenu {
        let m = NSMenu()
        for mode in FilterMode.allCases {
            let it = m.addItem(withTitle: mode.title, action: #selector(setMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = filter.mode == mode ? .on : .off
        }
        return m
    }

    @objc private func setMode(_ s: NSMenuItem) {
        filter.mode = FilterMode(rawValue: s.representedObject as? String ?? "") ?? .plainText
        modeButton.title = filter.mode.title
        needsLayout = true
        notify()
    }

    func controlTextDidChange(_ obj: Notification) {
        filter.text = field.stringValue
        notify()
    }

    @objc private func fieldAction() {
        guard field.stringValue != filter.text else { return }
        filter.text = field.stringValue
        notify()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if field.stringValue.isEmpty { delegate?.filterBarClosed(self) } else { field.stringValue = ""; filter.text = ""; notify() }
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            window?.makeFirstResponder(nil)
            NotificationCenter.default.post(name: .focusView, object: window)
            return true
        }
        return false
    }

    private func notify() {
        let valid = filter.matcher() != nil
        invalidLabel.isHidden = valid
        needsLayout = true
        if valid { delegate?.filterBar(self, changed: filter) }
    }

    func clear() {
        field.stringValue = ""
        filter.text = ""
        notify()
    }

    func focus() { window?.makeFirstResponder(field) }
}

extension Notification.Name {
    static let focusView = Notification.Name("PorpoiseFocusView")
}

// MARK: - Message bar

/// KMessageWidget: an inline error/information message with an optional action button.
final class MessageBar: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let close = FlatButton(icon: "dialog-close", tooltip: "Close")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionHandler: (() -> Void)?
    var isError = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.font
        label.textColor = Theme.windowText
        close.onClick = { [weak self] in self?.dismiss() }
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(runAction)
        actionButton.isHidden = true
        addSubview(label)
        addSubview(actionButton)
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called whenever the bar is shown or hidden (the container re-lays out).
    var onDismiss: (() -> Void)?

    @objc private func runAction() { actionHandler?() }

    func show(_ text: String, error: Bool, action: String? = nil, handler: (() -> Void)? = nil) {
        actionButton.title = action ?? ""
        actionButton.isHidden = action == nil
        actionHandler = handler
        actionButton.sizeToFit()
        label.stringValue = text
        isError = error
        isHidden = false
        // Same frame as last time means no automatic layout pass; the button and label still move.
        needsLayout = true
        needsDisplay = true
        onDismiss?()
    }

    func dismiss() { isHidden = true; onDismiss?() }
    var text: String { label.stringValue }

    override func layout() {
        super.layout()
        let aw = actionButton.isHidden ? 0 : actionButton.frame.width + 10
        actionButton.frame.origin = CGPoint(x: bounds.width - 40 - aw, y: (bounds.height - actionButton.frame.height) / 2)
        label.frame = CGRect(x: 34, y: 6, width: bounds.width - 76 - aw, height: bounds.height - 12)
        close.frame = CGRect(x: bounds.width - 34, y: (bounds.height - 26) / 2, width: 26, height: 26)
    }

    override func draw(_ dirty: NSRect) {
        let c = isError ? Theme.negativeText : Theme.neutralText
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 4, yRadius: 4)
        c.withAlphaComponent(0.2).setFill(); p.fill()
        c.setStroke(); p.stroke()
        Icons.shared.image(isError ? "dialog-error" : "dialog-information", size: 16)?
            .draw(in: CGRect(x: 14, y: bounds.midY - 8, width: 16, height: 16))
    }
}

// MARK: - Zoom glyph

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
