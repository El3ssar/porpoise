import AppKit
import PorpoiseCore
import PorpoiseServices

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, select index: Int)
    func tabBar(_ bar: TabBarView, close index: Int)
    func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?)
    func tabBar(_ bar: TabBarView, move from: Int, to: Int)
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu?
    /// The folder tab `index` shows (where items dropped on it go).
    func tabBar(_ bar: TabBarView, folderAt index: Int) -> URL?
    func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int, operation: NSDragOperation)
    func tabBar(_ bar: TabBarView, detach index: Int)
}

/// Dolphin's in-window tab bar (document mode): folder name tabs, close buttons, "+" button.
final class TabBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    weak var delegate: TabBarDelegate?
    var titles: [String] = [] { didSet { relayout() } }
    var icons: [String] = []
    var selected = 0 { didSet { revealTab(selected); relayout() } }
    private var firstVisible = 0
    private var visibleCapacity = 1
    private let overflow = FlatButton(icon: "go-down", tooltip: "Show All Tabs")
    private var rects: [CGRect] = []
    private var closeRects: [CGRect] = []
    private var plusRect: CGRect = .zero
    private var hover: Int?
    private var hoverClose: Int?
    private var hoverPlus = false
    private var dragging: (index: Int, startX: CGFloat, offset: CGFloat)?
    private var tracking: NSTrackingArea?
    private let springLoader = SpringLoader()
    private var dropTab: Int?

    override var isFlipped: Bool { true }

    /// VoiceOver: each tab, then its close button (there even when the tab is too narrow to draw one), and "+".
    override func accessibilityChildren() -> [Any]? {
        var out: [Any] = rects.indices.filter { !rects[$0].isEmpty }.flatMap { i -> [Any] in
            let title = titles.indices.contains(i) ? titles[i] : ""
            return [
                AccessibleRegion(
                    in: self, role: .radioButton, label: title,
                    frame: { [weak self] in self.flatMap { i < $0.rects.count ? $0.rects[i] : nil } ?? .zero },
                    selected: { [weak self] in self?.selected == i },
                    press: { [weak self] in if let self { self.delegate?.tabBar(self, select: i) } }),
                AccessibleRegion(
                    in: self, role: .button, label: "Close \(title)",
                    frame: { [weak self] in
                        guard let self, i < self.rects.count else { return .zero }
                        return self.closeRects[i] == .zero ? self.rects[i] : self.closeRects[i]
                    },
                    press: { [weak self] in if let self { self.delegate?.tabBar(self, close: i) } }),
            ]
        }
        out.append(
            AccessibleRegion(
                in: self, role: .button, label: "New Tab", frame: { [weak self] in self?.plusRect ?? .zero },
                press: { [weak self] in if let self { self.delegate?.tabBarNewTab(self, duplicate: nil) } }))
        if !overflow.isHidden { out.append(overflow) }
        return out
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropTargetPolicy.types)
        setAccessibilityRole(.tabGroup)
        overflow.menuProvider = { [weak self] in self?.allTabsMenu() }
        addSubview(overflow)
    }

    // MARK: Keyboard (Full Keyboard Access)

    /// The tab with keyboard focus: Tab reaches the bar, ←/→ move between tabs, Space or Return shows that tab.
    private var focused: Int? {
        didSet {
            if focused != oldValue { if let focused { revealTab(focused); relayout() }; noteFocusRingMaskChanged(); needsDisplay = true }
        }
    }

    override var acceptsFirstResponder: Bool { KeyboardAccess.isFull() && !rects.isEmpty }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        focused = min(selected, rects.count - 1)
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = nil
        return true
    }

    override var focusRingMaskBounds: NSRect { focused.map { $0 < rects.count ? rects[$0] : .zero } ?? .zero }
    override func drawFocusRingMask() {
        guard let i = focused, i < rects.count else { return }
        NSBezierPath(roundedRect: rects[i].insetBy(dx: 2, dy: 3), xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard let i = focused, !rects.isEmpty else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 123: focused = max(0, i - 1)  // ←
        case 124: focused = min(rects.count - 1, i + 1)  // →
        case 49, 36, 76: delegate?.tabBar(self, select: min(i, rects.count - 1))  // Space, Return, Enter
        default: super.keyDown(with: event)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 32
    /// Narrowest tab: just its icon.
    private static let minTabWidth: CGFloat = 22
    /// Below this width a tab shows its icon only, without title or close button.
    private static let compactTabWidth: CGFloat = 64

    private func revealTab(_ index: Int) {
        if index < firstVisible { firstVisible = max(0, index) }
        if index >= firstVisible + visibleCapacity { firstVisible = max(0, index - visibleCapacity + 1) }
    }

    private func allTabsMenu() -> NSMenu {
        let menu = NSMenu()
        for i in titles.indices {
            let path = delegate?.tabBar(self, folderAt: i).map {
                $0.isFileURL ? ($0.path as NSString).abbreviatingWithTildeInPath : RemoteFS.withoutPassword($0).absoluteString
            }
            let title = titles[i] + (path.map { " — " + $0 } ?? "")
            let item = NSMenuItem(title: title, action: #selector(chooseTab(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = i == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseTab(_ item: NSMenuItem) { delegate?.tabBar(self, select: item.tag) }

    private func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font]
        let available = max(24, bounds.width - 44)
        let overflowNeeded = CGFloat(titles.count) * 66 > available
        overflow.isHidden = !overflowNeeded
        overflow.frame = CGRect(x: max(0, bounds.width - 64), y: 4, width: 28, height: 24)
        plusRect = CGRect(x: max(0, bounds.width - 30), y: 4, width: 24, height: 24)
        let end = overflowNeeded ? overflow.frame.minX - 4 : plusRect.minX - 4
        let stripWidth = max(24, end - 6)
        let previousCapacity = visibleCapacity
        visibleCapacity = max(1, Int(stripWidth / 66))
        if visibleCapacity != previousCapacity { revealTab(focused ?? selected) }
        firstVisible = min(firstVisible, max(0, titles.count - visibleCapacity))
        if !overflowNeeded { firstVisible = 0 }
        rects = Array(repeating: .zero, count: titles.count)
        closeRects = Array(repeating: .zero, count: titles.count)
        let count = min(titles.count - firstVisible, visibleCapacity)
        guard count > 0 else { needsDisplay = true; return }
        let share = max(Self.minTabWidth, stripWidth / CGFloat(count) - 2)
        var x: CGFloat = 6
        for i in firstVisible..<(firstVisible + count) {
            let wanted: CGFloat
            switch Settings.shared.tabStyle {
            case .autoSize: wanted = min(260, max(110, (titles[i] as NSString).size(withAttributes: attrs).width + 64))
            case .fixedSize: wanted = 225
            case .fullWidth: wanted = share
            }
            let width = min(wanted, share)
            rects[i] = CGRect(x: x, y: 4, width: width, height: max(0, bounds.height - 4))
            if width >= Self.compactTabWidth { closeRects[i] = CGRect(x: x + width - 24, y: 4 + (bounds.height - 20) / 2, width: 16, height: 16) }
            x += width + 2
        }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard !overflow.isHidden else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return }
        firstVisible = min(max(0, titles.count - visibleCapacity), max(0, firstVisible + (delta < 0 ? 1 : -1)))
        relayout()
    }

    override func layout() { super.layout(); relayout() }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        // Baseline under the tabs; the active tab opens into the view below (document-mode tabs).
        Theme.frame.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (i, r0) in rects.enumerated() {
            guard !r0.isEmpty else { continue }
            var r = r0
            if let d = dragging, d.index == i { r.origin.x += d.offset }
            let isSel = i == selected
            let tabPath = NSBezierPath()
            let rad: CGFloat = 6
            tabPath.move(to: CGPoint(x: r.minX, y: r.maxY))
            tabPath.line(to: CGPoint(x: r.minX, y: r.minY + rad))
            tabPath.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
            tabPath.line(to: CGPoint(x: r.maxX - rad, y: r.minY))
            tabPath.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
            tabPath.line(to: CGPoint(x: r.maxX, y: r.maxY))
            if isSel {
                Theme.viewBackground.setFill()
                tabPath.fill()
                Theme.frame.setStroke()
                tabPath.lineWidth = 1
                tabPath.stroke()
                // Breeze's active-tab highlight line on top.
                Theme.selectionAlternate.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: CGRect(x: r.minX + 4, y: r.minY, width: r.width - 8, height: 2), xRadius: Tokens.Radius.xsmall,
                    yRadius: Tokens.Radius.xsmall
                ).fill()
                Theme.viewBackground.setFill()
                CGRect(x: r.minX + 0.5, y: r.maxY - 1.5, width: r.width - 1, height: 2).fill()
            } else if hover == i || dropTab == i {
                Theme.windowText.withAlphaComponent(0.06).setFill()
                tabPath.fill()
            }
            let icon = i < icons.count ? icons[i] : "folder"
            let compact = r.width < Self.compactTabWidth
            Icons.shared.image(icon, size: 16)?.draw(
                in: CGRect(x: compact ? r.midX - 8 : r.minX + 10, y: r.midY - 8, width: 16, height: 16), from: .zero,
                operation: .sourceOver, fraction: isSel ? 1 : 0.7, respectFlipped: true, hints: nil)
            if compact { continue }
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font, .paragraphStyle: p,
                .foregroundColor: isSel ? Theme.windowText : Theme.windowTextInactive.withAlphaComponent(0.85),
            ]
            let closeW: CGFloat = Settings.shared.closeButtonsOnTabs ? 28 : 8
            (titles[i] as NSString).draw(in: CGRect(x: r.minX + 32, y: r.midY - 9, width: r.width - 32 - closeW, height: 18), withAttributes: attrs)
            if Settings.shared.closeButtonsOnTabs {
                var cr = closeRects[i]
                if let d = dragging, d.index == i { cr.origin.x += d.offset }
                if hoverClose == i {
                    Theme.windowText.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: cr, xRadius: Tokens.Radius.small, yRadius: Tokens.Radius.small).fill()
                }
                let x = NSBezierPath()
                let c = CGPoint(x: cr.midX, y: cr.midY), d: CGFloat = 3.5
                x.move(to: CGPoint(x: c.x - d, y: c.y - d)); x.line(to: CGPoint(x: c.x + d, y: c.y + d))
                x.move(to: CGPoint(x: c.x + d, y: c.y - d)); x.line(to: CGPoint(x: c.x - d, y: c.y + d))
                x.lineWidth = 1.3
                x.lineCapStyle = .round
                Theme.windowText.withAlphaComponent(hoverClose == i ? 1 : (isSel || hover == i ? 0.7 : 0.35)).setStroke()
                x.stroke()
            }
        }
        if hoverPlus {
            Theme.windowText.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: plusRect, xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row).fill()
        }
        Icons.shared.image("list-add", size: 16)?.draw(
            in: plusRect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver,
            fraction: 0.8, respectFlipped: true, hints: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    private func tab(at p: CGPoint) -> Int? { rects.firstIndex { $0.contains(p) } }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = tab(at: p)
        hoverClose = closeRects.firstIndex { $0.contains(p) }
        hoverPlus = plusRect.contains(p)
        // Icon-only tabs name their folder in the tooltip.
        toolTip = hoverPlus ? "Open a new tab" : hover.flatMap { rects[$0].width < Self.compactTabWidth ? titles[$0] : nil }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hover = nil; hoverClose = nil; hoverPlus = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { delegate?.tabBarNewTab(self, duplicate: nil); return }
        guard let i = tab(at: p) else {
            if event.clickCount == 2 { delegate?.tabBarNewTab(self, duplicate: selected); return }
            // Empty tab bar space moves the window, like a Mac title bar.
            let start = event.locationInWindow
            while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if e.type == .leftMouseUp { return }
                if hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 3 { window?.performDrag(with: event); return }
            }
            return
        }
        if event.clickCount == 2 { delegate?.tabBarNewTab(self, duplicate: i); return }
        if Settings.shared.closeButtonsOnTabs, closeRects[i].contains(p) { delegate?.tabBar(self, close: i); return }
        delegate?.tabBar(self, select: i)
        dragging = (i, p.x, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.y > bounds.height + 40 || p.y < -40 {
            // Dragged out of the bar: detach into a new window.
            dragging = nil
            needsDisplay = true
            delegate?.tabBar(self, detach: d.index)
            return
        }
        d.offset = p.x - d.startX
        dragging = d
        let center = rects[d.index].midX + d.offset
        if let target = rects.firstIndex(where: { $0.contains(CGPoint(x: center, y: 5)) }), target != d.index {
            delegate?.tabBar(self, move: d.index, to: target)
            let shift = rects[target].minX - rects[d.index].minX
            dragging = (target, d.startX + shift, d.offset - shift)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        needsDisplay = true
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes a tab; other buttons (the mouse's Back and Forward) go up the responder chain.
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if let i = tab(at: convert(event.locationInWindow, from: nil)) { delegate?.tabBar(self, close: i) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = tab(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return delegate?.tabBar(self, menuFor: i)
    }

    // Dragging items over a tab switches to it after a pause (Dolphin); dropped on it, they go to its folder.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let i = tab(at: convert(sender.draggingLocation, from: nil))
        if i != dropTab {
            dropTab = i
            needsDisplay = true
        }
        springLoader.hover(i == selected ? nil : i) { [weak self] in
            guard let self, let i else { return }
            self.delegate?.tabBar(self, select: i)
        }
        guard let i, let folder = delegate?.tabBar(self, folderAt: i), DropTargetPolicy.accepts(DropTargetPolicy.urls(sender), into: folder)
        else { return [] }
        return DropTargetPolicy.operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDrop() }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DropTargetPolicy.dragEnded()
        endDrop()
    }

    private func endDrop() {
        dropTab = nil
        springLoader.cancel()
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrop() }
        let urls = DropTargetPolicy.urls(sender)
        guard let i = tab(at: convert(sender.draggingLocation, from: nil)), let folder = delegate?.tabBar(self, folderAt: i),
            DropTargetPolicy.accepts(urls, into: folder)
        else { return false }
        delegate?.tabBar(self, drop: urls, onto: i, operation: DropTargetPolicy.operation(for: sender))
        return true
    }
}
