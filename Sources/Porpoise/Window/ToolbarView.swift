import AppKit
import PorpoiseCore
import PorpoiseServices

/// The default toolbar (Back, Forward, Up, View settings, location, Split, Search, then Dolphin's menu or, with the Mac
/// key set, Finder's Share and Action ⋯), presented like a macOS 26 unified toolbar: glass capsules over a translucent
/// bar that sits right of the full-height sidebar.
final class ToolbarView: NSView {
    let linkFolders = PairToolbarButton(icon: nil, tooltip: "Linked Browsing")
    private let pairGroup = GlassGroup()
    let back = FlatButton(icon: "go-previous", tooltip: "Back")
    let forward = FlatButton(icon: "go-next", tooltip: "Forward")
    let up = FlatButton(icon: "go-up", tooltip: "Up")
    let viewMode = FlatButton(icon: "view-list-icons", tooltip: "Change View Mode")
    let split = FlatButton(icon: "view-split-left-right", title: "Split", tooltip: "Split view")
    var splitTooltipTitle = "Split view"
    let search = FlatButton(icon: "edit-find", tooltip: "Search")
    let hamburger = FlatButton(icon: "application-menu", tooltip: "Main Menu")
    private var shortcutsObserver: NSObjectProtocol?
    private var customGroups: [ToolbarCommand: GlassGroup] = [:]
    private var extraButtons: [ToolbarCommand: FlatButton] = [:]
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.78)
    private let hairline = NSView()
    private let navGroup = GlassGroup()
    private let modeGroup = GlassGroup()
    private let actionGroup = GlassGroup()
    private let transferGroup = GlassGroup()
    let transfers = TransferToolbarButton()
    private let fieldGroups = [GlassGroup(), GlassGroup()]
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
        for b in [back, forward, viewMode, split, search, hamburger] { b.iconSize = 18; b.cornerRadius = Self.buttonSize.height / 2 }
        hairline.wantsLayer = true
        Theme.whenChanged(hairline) { [weak hairline] in hairline?.layer?.backgroundColor = Theme.hairline.cgColor }
        addSubview(background)
        addSubview(pairGroup)
        pairGroup.content.addSubview(linkFolders)
        linkFolders.iconName = "insert-link"
        linkFolders.identifier = .init("Porpoise.toolbar.link")

        navGroup.content.addSubview(back)
        navGroup.content.addSubview(forward)
        navGroup.content.addSubview(up)
        modeGroup.content.addSubview(viewMode)
        transfers.visibilityChanged = { [weak self] in self?.needsLayout = true }
        transferGroup.content.addSubview(transfers)
        addSubview(transferGroup)
        for b in [split, search, hamburger] { actionGroup.content.addSubview(b) }
        for v in [navGroup, modeGroup, fieldGroups[0], fieldGroups[1], actionGroup, hairline] as [NSView] { addSubview(v) }
        for command in ToolbarCommand.allCases where ![.back, .forward, .up, .viewMode, .location, .split, .search, .menu].contains(command) {
            let button = FlatButton(icon: nil, tooltip: command.title)
            button.iconSize = 18
            button.onClick = { [weak self] in self?.perform(command) }
            extraButtons[command] = button
        }
        for command in ToolbarCommand.allCases {
            button(for: command)?.identifier = NSUserInterfaceItemIdentifier(command.toolbarIdentifier.rawValue)
            if let extra = extraButtons[command] { extra.iconName = command.iconName }
        }
        fieldGroups[0].identifier = .init("Porpoise.toolbar.location.primary")
        fieldGroups[1].identifier = .init("Porpoise.toolbar.location.secondary")
        setAccessibilityRole(.toolbar)
        shortcutsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            guard note.object == nil || ["shortcutKeySet", "keyboardShortcuts"].contains(note.object as? String ?? "") else { return }
            // The key set also picks the default toolbar's last buttons (☰, or Share and Action ⋯).
            DispatchQueue.main.async {
                self?.refreshShortcutTooltips(); self?.needsLayout = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let shortcutsObserver { NotificationCenter.default.removeObserver(shortcutsObserver) } }

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
        defer { refreshShortcutTooltips() }
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        if Settings.shared.toolbarCommands != Settings.shared.defaultToolbarCommands
            || Settings.shared.customToolsIfLoaded.contains(where: { $0.placements.contains(.toolbar) })
        {
            layoutCustom(); return
        }
        restoreDefaultGroups()
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

        // Icon only, like its neighbours: the title stays for its accessibility label, the tooltip says the rest.
        split.showsTitle = false
        let fieldMinX = modeGroup.frame.maxX + Self.fieldLeadingGap
        let splitW = split.intrinsicContentSize.width + 6
        let trailing = defaultTrailingButtons
        let actionW = splitW + CGFloat(trailing.count) * bw + 2 * inset
        actionGroup.frame = CGRect(x: bounds.width - Self.trailingMargin - actionW, y: gy, width: actionW, height: gh)
        split.frame = CGRect(x: inset, y: by, width: splitW, height: bh)
        var x = split.frame.maxX
        for b in trailing {
            b.frame = CGRect(x: x, y: by, width: bw, height: bh)
            x += bw
        }

        transferGroup.isHidden = transfers.isHidden
        transferGroup.frame = CGRect(x: actionGroup.frame.minX - 42, y: gy, width: 34, height: gh)
        transfers.frame = CGRect(origin: .zero, size: transferGroup.frame.size)
        layoutFields(
            from: fieldMinX, to: transferGroup.frame.minX - Self.fieldTrailingGap, y: gy, height: gh)
    }

    func refreshShortcutTooltips() {
        typealias W = MainWindowController
        func update(_ view: NSView, title: String, action: Selector, tag: Int = 0) {
            let shortcut = MenuCommandRegistry.shared.shortcut(for: action, tag: tag)
            let tooltip = shortcut.isEmpty ? title : title + " (" + shortcut.display + ")"
            guard view.toolTip != tooltip else { return }
            view.toolTip = tooltip; view.setAccessibilityHelp(tooltip)
        }
        update(back, title: "Back", action: #selector(W.goBack(_:)))
        update(forward, title: "Forward", action: #selector(W.goForward(_:)))
        update(up, title: "Up", action: #selector(W.goUp(_:)))
        update(search, title: "Search", action: #selector(W.showSearch(_:)))
        update(split, title: splitTooltipTitle, action: #selector(W.toggleSplit(_:)))
        update(linkFolders, title: "Linked Browsing", action: #selector(W.toggleLinkedBrowsing(_:)))
        for (command, button) in extraButtons {
            switch command {
            case .reload: update(button, title: command.title, action: #selector(W.reloadView(_:)))
            case .newTab: update(button, title: command.title, action: #selector(W.newTab(_:)))
            case .terminal: update(button, title: command.title, action: #selector(W.togglePanel(_:)), tag: 3)
            case .commandPalette: update(button, title: command.title, action: #selector(AppDelegate.showCommandPalette(_:)))
            case .link: update(button, title: command.title, action: #selector(W.toggleLinkedBrowsing(_:)))
            case .share: update(button, title: command.title, action: #selector(W.shareItems(_:)))
            case .airDrop: update(button, title: command.title, action: #selector(W.airDropItems(_:)))
            default: break
            }
        }
    }

    private func button(for command: ToolbarCommand) -> FlatButton? {
        switch command {
        case .back: return back
        case .forward: return forward
        case .up: return up
        case .viewMode: return viewMode
        case .split: return split
        case .search: return search
        case .menu: return hamburger
        case .location: return nil
        default: return extraButtons[command]
        }
    }
    /// The button for a command, if the toolbar has it (tests).
    func buttonForTesting(_ command: ToolbarCommand) -> FlatButton? { button(for: command) }

    func perform(_ command: ToolbarCommand) {
        guard let controller = window?.windowController as? MainWindowController else { return }
        switch command {
        case .reload: controller.reloadView(nil)
        case .newTab: controller.newTab(nil)
        case .terminal:
            let item = NSMenuItem(); item.tag = 3; controller.togglePanel(item)
        case .commandPalette: AppDelegate.shared.showCommandPalette(nil)
        case .link: controller.toggleLinkedBrowsing(nil)
        case .customTools: controller.showToolbarCustomTools(extraButtons[command])
        case .share: controller.shareItems(extraButtons[command])
        case .airDrop: controller.airDropItems(extraButtons[command])
        case .action: if let button = extraButtons[command] { controller.showActionMenu(from: button) }
        default: break
        }
    }

    /// After Split in the default layout: Search, then Dolphin's menu, or Finder's Share and Action ⋯ with the Mac keys.
    private var defaultTrailingButtons: [FlatButton] {
        Settings.shared.shortcutKeySet == .dolphin ? [search, hamburger] : [search, extraButtons[.share], extraButtons[.action]].compactMap { $0 }
    }
    private func restoreDefaultGroups() {
        customGroups.values.forEach { $0.isHidden = true }
        navGroup.isHidden = false; modeGroup.isHidden = false; actionGroup.isHidden = false
        viewMode.showsMenuIndicator = true; viewMode.isSplitButton = true
        let trailing = defaultTrailingButtons
        for (button, group) in [(back, navGroup), (forward, navGroup), (up, navGroup), (viewMode, modeGroup), (split, actionGroup)]
            + trailing.map({ ($0, actionGroup) })
        {
            if button.superview !== group.content { button.removeFromSuperview(); group.content.addSubview(button) }
            button.isHidden = false
        }
        // The other key set's trailing buttons, left in the capsule from before a switch.
        for b in [hamburger] + [extraButtons[.share], extraButtons[.action]].compactMap({ $0 }) where !trailing.contains(where: { $0 === b }) {
            if b.superview === actionGroup.content { b.removeFromSuperview() }
        }
    }
    private func layoutCustom() {
        navGroup.isHidden = true; modeGroup.isHidden = true; actionGroup.isHidden = true
        viewMode.showsMenuIndicator = false; viewMode.isSplitButton = false
        customGroups.values.forEach { $0.isHidden = true }
        var commands = Settings.shared.toolbarCommands
        if Settings.shared.customToolsIfLoaded.contains(where: { $0.placements.contains(.toolbar) }), !commands.contains(.customTools) {
            commands.append(.customTools)
        }
        let gh = Self.capsuleHeight, gy = (bounds.height - gh) / 2
        let gap: CGFloat = 6
        transferGroup.isHidden = transfers.isHidden
        transferGroup.frame = CGRect(x: bounds.width - Self.trailingMargin - 34, y: gy, width: 34, height: gh)
        transfers.frame = CGRect(origin: .zero, size: transferGroup.frame.size)
        let available = max(0, bounds.width - leftInset - Self.trailingMargin - 42)
        let capacity = max(1, Int((available - 80) / 36))
        if commands.filter({ $0 != .location }).count > capacity {
            let visible = Set(commands.filter { $0 != .location && $0 != .menu }.prefix(max(0, capacity - 1)))
            commands = commands.filter { $0 == .location || visible.contains($0) }
            commands.append(.menu)  // Overflow actions remain reachable through the main menu.
        }
        let fixed = commands.filter { $0 != .location }
        let desiredField = navigatorViews.count == 2 ? 180.0 : 100.0
        let bw = max(24, min(42, (available - desiredField - CGFloat(commands.count - 1) * gap) / CGFloat(max(1, fixed.count))))
        let locationWidth = max(0, available - CGFloat(fixed.count) * bw - CGFloat(commands.count - 1) * gap)
        var x = leftInset
        split.showsTitle = false
        for command in commands {
            if command == .location {
                layoutFields(from: x, to: x + locationWidth, y: gy, height: gh); x += locationWidth + gap; continue
            }
            guard let button = button(for: command) else { continue }
            let group: GlassGroup
            if let existing = customGroups[command] {
                group = existing
            } else {
                group = GlassGroup(); customGroups[command] = group; addSubview(group)
            }
            if button.superview !== group.content { button.removeFromSuperview(); group.content.addSubview(button) }
            group.isHidden = false; button.isHidden = false
            group.frame = CGRect(x: x, y: gy, width: bw, height: gh)
            button.frame = group.bounds.insetBy(dx: 3, dy: 3)
            x += bw + gap
        }
    }

    /// Location field(s) between `minX` and `maxX`: capped in width so the toolbar keeps free space to grab the
    /// window; in a split, one field per pane, the second starting where the right pane starts (Dolphin).
    private func layoutFields(from minX: CGFloat, to maxX: CGFloat, y: CGFloat, height: CGFloat) {
        let seam = paneRanges.count == 2 ? convert(CGPoint(x: paneRanges[1].lowerBound, y: 0), from: nil).x : (minX + maxX) / 2
        let hasPair = navigatorViews.count == 2 && seam - 40 - minX >= 160 && maxX - seam - 40 >= 160
        pairGroup.isHidden = !hasPair
        let gap: CGFloat = hasPair ? 40 : Self.fieldSpacing
        let available = max(0, maxX - minX)
        if navigatorViews.count == 2, paneRanges.count == 2 {
            // Each field at least minFieldWidth while there is room for both; never over the buttons on the right.
            let splitX = convert(CGPoint(x: paneRanges[1].lowerBound, y: 0), from: nil).x
            let minW = min(Self.minFieldWidth, max(0, (available - gap) / 2), max(0, splitX - gap - minX))
            if hasPair {
                pairGroup.frame = CGRect(x: splitX - 17, y: y + (height - 34) / 2, width: 34, height: 34)
                linkFolders.frame = CGRect(x: 4, y: 3, width: 28, height: 28)
            }
            let rightX = hasPair ? min(max(splitX + gap, minX + minW + gap), minX + available - minW) : minX + (available + gap) / 2
            let leftW = hasPair ? max(minW, min(splitX - gap, rightX - gap) - minX) : (available - gap) / 2
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

private extension ToolbarCommand {
    var iconName: String {
        switch self {
        case .reload: return "view-refresh"
        case .newTab: return "tab-new"
        case .terminal: return "utilities-terminal"
        case .commandPalette: return "system-search"
        case .link: return "insert-link"
        case .customTools: return "system-run"
        case .share: return "document-share"
        case .airDrop: return "airdrop"
        case .action: return "overflow-menu"
        default: return "application-menu"
        }
    }
}

/// Seam controls share the parent glass capsule; each toggles a circular accent fill, never a square bezel.
final class PairToolbarButton: FlatButton {
    private let symbol = PairToolbarSymbolView()
    private var shownSymbol = ""
    override init(frame: CGRect) {
        super.init(frame: frame); addSubview(symbol); symbol.imageScaling = .scaleProportionallyUpOrDown; symbol.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); symbol.frame = bounds.insetBy(dx: 5, dy: 5) }
    override func draw(_ dirty: NSRect) {
        if isToggled {
            (iconName == "edit-unlink" ? Theme.transferChanged.withAlphaComponent(0.16) : Theme.selection.withAlphaComponent(0.32)).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let name = "link"
        if shownSymbol != name {
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            shownSymbol = name
        }
        symbol.contentTintColor = iconName == "edit-unlink" ? Theme.transferChanged : (isToggled ? Theme.accent : Theme.windowText)
        symbol.alphaValue = isEnabled ? 1 : 0.35
        if iconName == "edit-unlink" {
            Theme.transferChanged.setStroke(); let slash = NSBezierPath(); slash.move(to: CGPoint(x: 5, y: 5)); slash.line(to: CGPoint(x: 23, y: 23));
            slash.lineWidth = 1.5; slash.stroke()
        }
    }
}

private final class PairToolbarSymbolView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
