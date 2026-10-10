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

/// Dolphin's default toolbar (Back, Forward, View settings, location, Split, Search, menu), presented like a
/// macOS 26 unified toolbar: glass capsules over a translucent bar that sits right of the full-height sidebar.
final class ToolbarView: NSView {
    let back = FlatButton(icon: "go-previous", tooltip: "Back")
    let forward = FlatButton(icon: "go-next", tooltip: "Forward")
    let up = FlatButton(icon: "go-up", tooltip: "Up (⌘↑)")
    let viewMode = FlatButton(icon: "view-list-icons", tooltip: "Change View Mode")
    let split = FlatButton(icon: "view-split-left-right", title: "Split", tooltip: "Split view")
    let search = FlatButton(icon: "edit-find", tooltip: "Search")
    let hamburger = FlatButton(icon: "application-menu", tooltip: "Main Menu")
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.78)
    private let hairline = NSView()
    private let navGroup = GlassGroup()
    private let modeGroup = GlassGroup()
    private let actionGroup = GlassGroup()
    private let fieldGroups = [GlassGroup(cornerRadius: 17), GlassGroup(cornerRadius: 17)]
    /// Space left of the first capsule (room for the traffic lights when there is no sidebar).
    var leftInset: CGFloat = 84 { didSet { needsLayout = true } }
    /// Navigator areas aligned to the panes below (split view shows one per pane).
    var navigatorViews: [BreadcrumbView] = [] {
        didSet {
            guard !navigatorViews.elementsEqual(oldValue, by: ===) else { return }
            for g in fieldGroups { g.content.subviews.filter { v in !navigatorViews.contains { $0 === v } }.forEach { $0.removeFromSuperview() } }
            for (i, n) in navigatorViews.enumerated() where n.superview !== fieldGroups[i].content {
                n.removeFromSuperview()
                fieldGroups[i].content.addSubview(n)
            }
            fieldGroups[1].isHidden = navigatorViews.count < 2
            needsLayout = true
        }
    }
    /// x-ranges (in window coordinates) of the split panes, so each navigator sits above its pane.
    var paneRanges: [ClosedRange<CGFloat>] = [] { didSet { if paneRanges != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // View Settings is a split button with an arrow; Back/Forward history menus open on long-press or
        // right-click with no indicator, like Mac toolbars.
        viewMode.showsMenuIndicator = true
        viewMode.isSplitButton = true
        if !IconTheme.shared.has("application-menu") { hamburger.iconName = "open-menu-symbolic" }
        for b in [back, forward, viewMode, split, search, hamburger] { b.iconSize = 18; b.cornerRadius = 13 }
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        addSubview(background)
        navGroup.content.addSubview(back)
        navGroup.content.addSubview(forward)
        navGroup.content.addSubview(up)
        modeGroup.content.addSubview(viewMode)
        for b in [split, search, hamburger] { actionGroup.content.addSubview(b) }
        for v in [navGroup, modeGroup, fieldGroups[0], fieldGroups[1], actionGroup, hairline] as [NSView] { addSubview(v) }
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    // Breeze-like toolbar metrics.
    private static let capsuleHeight: CGFloat = 34
    private static let buttonSize = CGSize(width: 34, height: 28)
    /// Padding inside a capsule around its buttons.
    private static let capsuleInset: CGFloat = 4
    private static let groupSpacing: CGFloat = 8
    private static let viewModeWidth: CGFloat = 50
    /// Gaps before and after the location field(s).
    private static let fieldLeadingGap: CGFloat = 12
    private static let fieldTrailingGap: CGFloat = 16
    private static let fieldSpacing: CGFloat = 6
    private static let minFieldWidth: CGFloat = 120
    private static let minUsableFieldWidth: CGFloat = 60
    private static let trailingMargin: CGFloat = 12

    override func layout() {
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let gh = Self.capsuleHeight
        let gy = (bounds.height - gh) / 2
        let inset = Self.capsuleInset
        let bw = Self.buttonSize.width, bh = Self.buttonSize.height
        let by = (gh - bh) / 2

        navGroup.frame = CGRect(x: leftInset, y: gy, width: 3 * bw + 2 * inset, height: gh)
        back.frame = CGRect(x: inset, y: by, width: bw, height: bh)
        forward.frame = CGRect(x: back.frame.maxX, y: by, width: bw, height: bh)
        up.frame = CGRect(x: forward.frame.maxX, y: by, width: bw, height: bh)

        let modeW = Self.viewModeWidth
        modeGroup.frame = CGRect(x: navGroup.frame.maxX + Self.groupSpacing, y: gy, width: modeW + 2 * inset, height: gh)
        viewMode.frame = CGRect(x: inset, y: by, width: modeW, height: bh)

        // Short of room for the location field, the Split button drops its title.
        let fieldMinX = modeGroup.frame.maxX + Self.fieldLeadingGap
        let fixedW = 2 * bw + 2 * inset + 6
        let fieldsMinW = navigatorViews.count == 2 ? 2 * Self.minFieldWidth + Self.fieldSpacing : Self.minFieldWidth
        split.showsTitle = bounds.width - Self.trailingMargin - fixedW - split.width(showingTitle: true) - Self.fieldTrailingGap - fieldMinX
            >= fieldsMinW
        let splitW = split.intrinsicContentSize.width + 6
        let actionW = splitW + 2 * bw + 2 * inset
        actionGroup.frame = CGRect(x: bounds.width - Self.trailingMargin - actionW, y: gy, width: actionW, height: gh)
        split.frame = CGRect(x: inset, y: by, width: splitW, height: bh)
        search.frame = CGRect(x: split.frame.maxX, y: by, width: bw, height: bh)
        hamburger.frame = CGRect(x: search.frame.maxX, y: by, width: bw, height: bh)

        layoutFields(from: fieldMinX, to: actionGroup.frame.minX - Self.fieldTrailingGap, y: gy, height: gh)
    }

    /// Location field(s) between `minX` and `maxX`: capped in width so the toolbar keeps free space to grab the
    /// window; in a split, one field per pane, the second starting where the right pane starts (Dolphin).
    private func layoutFields(from minX: CGFloat, to maxX: CGFloat, y: CGFloat, height: CGFloat) {
        let gap = Self.fieldSpacing
        let available = max(0, maxX - minX)
        if navigatorViews.count == 2, paneRanges.count == 2 {
            // Each field at least minFieldWidth while there is room for both; never over the buttons on the right.
            let minW = min(Self.minFieldWidth, max(0, (available - gap) / 2))
            let splitX = convert(CGPoint(x: paneRanges[1].lowerBound, y: 0), from: nil).x
            let rightX = min(max(splitX + gap, minX + minW + gap), minX + available - minW)
            let leftW = max(minW, min(splitX - gap, rightX - gap) - minX)
            fieldGroups[0].frame = CGRect(x: minX, y: y, width: leftW, height: height)
            fieldGroups[1].frame = CGRect(x: rightX, y: y, width: max(0, minX + available - rightX), height: height)
        } else {
            let w = min(available, max(360, min(760, available * 0.86)))
            fieldGroups[0].frame = CGRect(x: minX, y: y, width: w, height: height)
        }
        // A sliver of a field shows nothing useful (a tiny window with sidebar): leave the space empty instead.
        for (i, g) in fieldGroups.enumerated() { g.isHidden = i >= navigatorViews.count || g.frame.width < Self.minUsableFieldWidth }
        for (i, n) in navigatorViews.enumerated() { n.frame = fieldGroups[i].bounds.insetBy(dx: 4, dy: 1) }
    }

    // Empty toolbar space behaves like a title bar: drag moves the window, double-click zooms.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }
}

// MARK: - Tab bar

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, select index: Int)
    func tabBar(_ bar: TabBarView, close index: Int)
    func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?)
    func tabBar(_ bar: TabBarView, move from: Int, to: Int)
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu?
    func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int)
    func tabBar(_ bar: TabBarView, detach index: Int)
}

/// Dolphin's in-window tab bar (document mode): folder name tabs, close buttons, "+" button.
final class TabBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    weak var delegate: TabBarDelegate?
    var titles: [String] = [] { didSet { relayout() } }
    var icons: [String] = []
    var selected = 0 { didSet { needsDisplay = true } }
    private var rects: [CGRect] = []
    private var closeRects: [CGRect] = []
    private var plusRect: CGRect = .zero
    private var hover: Int?
    private var hoverClose: Int?
    private var hoverPlus = false
    private var dragging: (index: Int, startX: CGFloat, offset: CGFloat)?
    private var tracking: NSTrackingArea?
    private var dropTimer: Timer?
    private var dropTab: Int?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 32
    /// Narrowest tab: just its icon.
    private static let minTabWidth: CGFloat = 22
    /// Below this width a tab shows its icon only, without title or close button.
    private static let compactTabWidth: CGFloat = 64

    private func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font]
        var x: CGFloat = 6
        rects = []
        closeRects = []
        let style = Settings.shared.tabStyle
        let n = CGFloat(max(1, titles.count))
        let avail = bounds.width - 44
        // Equal share of the bar; with many tabs they narrow down to their icon so every tab (and "+") stays reachable.
        let share = max(Self.minTabWidth, (avail - 6) / n - 2)
        var widths = titles.map { t -> CGFloat in
            switch style {
            case .autoSize: min(260, max(110, (t as NSString).size(withAttributes: attrs).width + 64))
            case .fixedSize: 225
            case .fullWidth: share
            }
        }
        if widths.reduce(0, +) + 2 * n > avail - 6 { widths = widths.map { min($0, share) } }
        for w in widths {
            rects.append(CGRect(x: x, y: 4, width: w, height: bounds.height - 4))
            // Narrow tabs have no room for a close button (middle-click, the context menu and ⌘W still close them).
            closeRects.append(w < Self.compactTabWidth ? .zero : CGRect(x: x + w - 24, y: 4 + (bounds.height - 4 - 16) / 2, width: 16, height: 16))
            x += w + 2
        }
        plusRect = CGRect(x: x + 4, y: 4 + (bounds.height - 4 - 24) / 2, width: 24, height: 24)
        needsDisplay = true
    }

    override func layout() { super.layout(); relayout() }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        // Baseline under the tabs; the active tab opens into the view below (document-mode tabs).
        Theme.frame.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (i, r0) in rects.enumerated() {
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
                NSBezierPath(roundedRect: CGRect(x: r.minX + 4, y: r.minY, width: r.width - 8, height: 2), xRadius: 1, yRadius: 1).fill()
                Theme.viewBackground.setFill()
                CGRect(x: r.minX + 0.5, y: r.maxY - 1.5, width: r.width - 1, height: 2).fill()
            } else if hover == i || dropTab == i {
                Theme.windowText.withAlphaComponent(0.06).setFill()
                tabPath.fill()
            }
            let icon = i < icons.count ? icons[i] : "folder"
            let compact = r.width < Self.compactTabWidth
            Icons.shared.image(icon, size: 16)?.draw(in: CGRect(x: compact ? r.midX - 8 : r.minX + 10, y: r.midY - 8, width: 16, height: 16), from: .zero,
                                                     operation: .sourceOver, fraction: isSel ? 1 : 0.7, respectFlipped: true, hints: nil)
            if compact { continue }
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .paragraphStyle: p,
                                                        .foregroundColor: isSel ? Theme.windowText : Theme.windowTextInactive.withAlphaComponent(0.85)]
            let closeW: CGFloat = Settings.shared.closeButtonsOnTabs ? 28 : 8
            (titles[i] as NSString).draw(in: CGRect(x: r.minX + 32, y: r.midY - 9, width: r.width - 32 - closeW, height: 18), withAttributes: attrs)
            if Settings.shared.closeButtonsOnTabs {
                var cr = closeRects[i]
                if let d = dragging, d.index == i { cr.origin.x += d.offset }
                if hoverClose == i {
                    Theme.windowText.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
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
            NSBezierPath(roundedRect: plusRect, xRadius: 6, yRadius: 6).fill()
        }
        Icons.shared.image("list-add", size: 16)?.draw(in: plusRect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver,
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
        // Middle-click closes a tab.
        if let i = tab(at: convert(event.locationInWindow, from: nil)) { delegate?.tabBar(self, close: i) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = tab(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return delegate?.tabBar(self, menuFor: i)
    }

    // Dragging files over a tab switches to it after 800 ms (Dolphin).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let i = tab(at: convert(sender.draggingLocation, from: nil))
        if i != dropTab {
            dropTab = i
            needsDisplay = true
            dropTimer?.invalidate()
            if let i, i != selected {
                dropTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.tabBar(self, select: i)
                }
            }
        }
        return i == nil ? [] : ItemListView.operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTab = nil
        dropTimer?.invalidate()
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropTab = nil; dropTimer?.invalidate(); needsDisplay = true }
        guard let i = tab(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        delegate?.tabBar(self, drop: urls, onto: i)
        return true
    }
}
