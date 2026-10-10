import AppKit
import PorpoiseCore
import PorpoiseServices

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
