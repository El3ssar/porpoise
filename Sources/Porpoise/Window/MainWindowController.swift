import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

/// Panel split view with a thin, Breeze-colored divider.
final class ThinSplitView: NSSplitView {
    var dividerColorOverride: NSColor?
    override var dividerColor: NSColor { dividerColorOverride ?? Theme.frame }
    override var dividerThickness: CGFloat { 1 }
}

final class DolphinWindow: NSWindow {
    /// Traffic-light placement of a macOS 26 window with a unified toolbar.
    private static let trafficLightsLeft: CGFloat = 16
    private static let trafficLightsSpacing: CGFloat = 20

    /// Keeps the traffic lights vertically centered in our taller, unified toolbar.
    func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let h = Theme.toolbarHeight
        var f = container.frame
        f.size.height = h
        f.origin.y = frame.height - h
        container.frame = f
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: Self.trafficLightsLeft + CGFloat(i) * Self.trafficLightsSpacing, y: (h - b.frame.height) / 2))
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }
}

/// Tab bar (when shown) on top of the current tab's views.
final class CenterColumnView: NSView {
    weak var tabBar: TabBarView?
    weak var host: NSView?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let t = tabBar, !t.isHidden {
            t.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabBarView.height)
            y = TabBarView.height
        }
        guard let host else { return }
        host.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        host.subviews.forEach { $0.frame = host.bounds }
    }
}

/// Right-hand column next to the full-height sidebar: room for the toolbar (in the title bar) on top,
/// then the views, inspector and terminal.
final class MainColumnView: NSView {
    weak var content: NSView?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let th = Theme.toolbarHeight
        content?.frame = CGRect(x: 0, y: th, width: bounds.width, height: max(0, bounds.height - th))
    }
}

/// The root view: toolbar, tab bar, panels and tab content (flipped, laid out manually).
final class RootView: NSView {
    weak var controller: MainWindowController?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        controller?.layoutRoot()
    }
    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill()
        dirty.fill()
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, ViewContainerDelegate, BreadcrumbDelegate,
    TabBarDelegate, PlacesPanelDelegate, NSSplitViewDelegate {

    let root = RootView()
    let toolbar = ToolbarView()
    let tabBar = TabBarView()
    let tabHost = NSView()
    /// Center column: Dolphin's tab bar sits above the views only (not above the Places panel).
    let centerColumn = CenterColumnView()
    let outer = ThinSplitView()       // [full-height sidebar, main column]
    let mainColumn = MainColumnView()
    let vSplit = ThinSplitView()      // [hSplit, terminal]  (inside the main column)
    let hSplit = ThinSplitView()      // [tab host, information]
    let leftStack = ThinSplitView()   // [places, folders]
    /// Sidebar host: translucent Desert-tinted material behind Places/Folders (Finder-style).
    let sidebar = NSView()
    private let sidebarMaterial = TintedMaterialView(material: .sidebar, alpha: 0.70)
    let placesScroll = NSScrollView()
    let places = PlacesPanel()
    lazy var folders = FoldersPanel()
    lazy var information = InformationPanel()
    lazy var terminal = TerminalPanel()

    private(set) var tabs: [PorpoiseTab] = []
    private(set) var current = 0
    var closedTabs: [(url: URL, split: URL?)] = []
    /// Block-based notification observers, removed when the window closes.
    private var observers: [NSObjectProtocol] = []

    var tab: PorpoiseTab { tabs[current] }
    var view: ViewContainer { tab.active }

    // Panel visibility (Dolphin defaults: only Places visible).
    var showPlaces = Settings.store.object(forKey: "panel.places") as? Bool ?? true
    var showFolders = Settings.store.bool(forKey: "panel.folders")
    var showInformation = Settings.store.bool(forKey: "panel.info")
    var showTerminal = Settings.store.bool(forKey: "panel.terminal")

    convenience init(urls: [URL], split: [URL?] = []) {
        let w = DolphinWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        self.init(window: w)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.windowBackground
        w.minSize = NSSize(width: 520, height: 320)
        w.tabbingMode = .disallowed
        if !Settings.isTesting { w.setFrameAutosaveName("PorpoiseMainWindow") }
        w.delegate = self
        w.isRestorable = false
        w.contentView = root
        root.controller = self
        setupViews()
        // In the given order (a restored session), not each one after the current tab.
        for (i, u) in (urls.isEmpty ? [Settings.shared.homeURL] : urls).enumerated() {
            addTab(url: u, select: i == 0, split: split[safe: i] ?? nil, afterCurrent: false)
        }
        if Settings.shared.splitViewOnStartup && !tab.isSplit { tab.openSplit() }
        showTab(0)
        if w.frame.origin == .zero { w.center() }
    }

    // MARK: - Setup

    private func setupViews() {
        placesScroll.documentView = places
        placesScroll.drawsBackground = false
        placesScroll.hasVerticalScroller = true
        placesScroll.autohidesScrollers = true
        placesScroll.scrollerStyle = .overlay
        places.setFrameSize(NSSize(width: 160, height: places.frame.height))   // height: the panel sizes itself to its rows
        places.autoresizingMask = [.width]
        places.delegate = self
        leftStack.isVertical = false
        leftStack.dividerStyle = .thin
        sidebar.addSubview(sidebarMaterial)
        sidebar.addSubview(leftStack)
        sidebarMaterial.autoresizingMask = [.width, .height]
        leftStack.autoresizingMask = [.width, .height]
        hSplit.isVertical = true
        hSplit.dividerStyle = .thin
        hSplit.delegate = self
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.delegate = self
        outer.dividerColorOverride = NSColor.black.withAlphaComponent(0.35)
        mainColumn.content = vSplit
        mainColumn.addSubview(vSplit)
        vSplit.isVertical = false
        vSplit.dividerStyle = .thin
        vSplit.delegate = self
        tabHost.wantsLayer = true
        centerColumn.tabBar = tabBar
        centerColumn.host = tabHost
        centerColumn.addSubview(tabBar)
        centerColumn.addSubview(tabHost)
        tabBar.delegate = self
        root.addSubview(toolbar)
        root.addSubview(outer)
        wireToolbar()
        folders.onNavigate = { [weak self] url, newTab in
            guard let self else { return }
            if newTab { self.addTab(url: url, select: false) } else if url != self.view.url { self.view.setURL(url) }
        }
        terminal.onDirectoryChange = { [weak self] url in
            guard let self, url.standardizedFileURL != self.view.url.standardizedFileURL else { return }
            self.view.setURL(url)
        }
        rebuildPanels()
        observeNotifications()
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping (MainWindowController, Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
            if let self { handler(self, n) }
        })
    }

    private func observeNotifications() {
        observe(Settings.changed) { me, note in me.settingsChanged(key: note.object as? String) }
        observe(PlacesModel.changed) { me, _ in me.placesChanged() }
        observe(.terminalExited) { me, n in
            // Like Dolphin: typing `exit` closes the Terminal panel; F4 opens a fresh shell.
            guard (n.object as? TerminalPanel) === me.terminal, me.showTerminal else { return }
            me.animatePanel(.terminal, show: false) { me.showTerminal = false }
            me.window?.makeFirstResponder(me.view.list)
        }
        observe(.splitResized) { me, n in
            // Only the visible tab's split moves the toolbar's navigators.
            if me.tabs.indices.contains(me.current), n.object as? PorpoiseTab === me.tab { me.alignNavigators() }
        }
        observe(.focusView) { me, n in
            guard (n.object as? NSWindow) === me.window else { return }
            me.window?.makeFirstResponder(me.view.list)
        }
        observe(FileOperationsController.cutChanged) { me, _ in
            me.allContainers.forEach {
                $0.list.cutURLs = FileOperationsController.shared.cutURLs
                $0.list.needsDisplay = true
            }
        }
        observe(.hoverChanged) { me, n in
            guard let c = n.object as? ViewContainer, me.allContainers.contains(where: { $0 === c }) else { return }
            if me.showInformation && Settings.shared.infoShowHovered {
                me.information.show(hovered: n.userInfo?["url"] as? URL, container: me.view)
            }
        }
    }

    /// Every view of every tab in this window.
    private var allContainers: [ViewContainer] { tabs.flatMap(\.containers) }

    private func wireToolbar() {
        toolbar.back.onClick = { [weak self] in self?.view.goBack() }
        toolbar.forward.onClick = { [weak self] in self?.view.goForward() }
        toolbar.up.onClick = { [weak self] in self?.goUp(nil) }
        toolbar.back.menuProvider = { [weak self] in self?.historyMenu(back: true) }
        toolbar.forward.menuProvider = { [weak self] in self?.historyMenu(back: false) }
        toolbar.viewMode.onClick = { [weak self] in self?.cycleViewMode() }
        toolbar.viewMode.menuProvider = { [weak self] in self?.viewSettingsMenu() }
        toolbar.split.onClick = { [weak self] in self?.toggleSplit(nil) }
        toolbar.split.menuProvider = { [weak self] in
            guard let self, self.tab.isSplit else { return nil }
            return self.splitMenu()
        }
        // A toggle: with the button as sender, showSearch(_:) closes an open search bar.
        toolbar.search.onClick = { [weak self] in self.map { $0.showSearch($0.toolbar.search) } }
        toolbar.hamburger.onClick = { [weak self] in
            guard let self else { return }
            self.hamburgerMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: self.toolbar.hamburger.bounds.height + 4), in: self.toolbar.hamburger)
        }
    }

    // MARK: - Panels

    /// Remembered panel sizes (Settings keys) and their defaults.
    private enum PanelSize: String {
        case sidebarWidth = "width.left", informationWidth = "width.right", terminalHeight = "height.terminal"

        var defaultValue: CGFloat {
            switch self {
            case .sidebarWidth: 160
            case .informationWidth: 280
            case .terminalHeight: 220
            }
        }
        /// Largest share of the window a panel may take; the files always keep the rest.
        var maxShare: CGFloat { self == .terminalHeight ? 0.7 : 0.45 }
        /// Room the files keep next to (below) the panel before it gives way in a small window.
        var filesMinimum: CGFloat { self == .terminalHeight ? 150 : 280 }
        var minimum: CGFloat {
            switch self {
            case .sidebarWidth: 120
            case .informationWidth: 200
            case .terminalHeight: 80
            }
        }

        /// The remembered size, kept within limits for a window/split of `extent` points (a bad saved value, e.g. from a
        /// transient layout, must never let a panel swallow the files).
        func saved(in extent: CGFloat) -> CGFloat {
            let v = Settings.store.double(forKey: rawValue).nonZero.map { CGFloat($0) } ?? defaultValue
            return clamp(v, extent: extent) ?? min(defaultValue, max(minimum, extent * maxShare))
        }

        func save(_ v: CGFloat, in extent: CGFloat) {
            if let ok = clamp(v, extent: extent), ok == v { Settings.store.set(Double(v), forKey: rawValue) }
        }

        private func clamp(_ v: CGFloat, extent: CGFloat) -> CGFloat? {
            guard extent > 0, v >= minimum, v <= extent * maxShare else { return nil }
            return v
        }

        /// The size the panel gets in a split of `extent` points: its remembered size, as far as the files keep
        /// `filesMinimum`; in a window too small for both it gives way, down to its minimum (or its share).
        func fitted(in extent: CGFloat, divider: CGFloat) -> CGFloat {
            let room = extent - filesMinimum - divider
            return max(min(saved(in: extent), room), floor(in: extent))
        }

        /// The smallest the panel gets: its minimum, or less in a window too small to give it that share.
        private func floor(in extent: CGFloat) -> CGFloat { max(0, min(minimum, extent * maxShare)) }

        /// Divider positions a drag may reach, so the dragged size stays one that `save` keeps: the panel between its
        /// minimum and its share, the files at least `filesMinimum`. For a panel after the files (Information,
        /// Terminal) the position is the files' extent; for the sidebar it is the panel's own width.
        func dividerRange(in extent: CGFloat, divider: CGFloat) -> ClosedRange<CGFloat> {
            let smallest = floor(in: extent)
            let largest = max(smallest, min(extent * maxShare, extent - filesMinimum - divider))
            if self == .sidebarWidth { return smallest...largest }
            return (extent - divider - largest)...(extent - divider - smallest)
        }
    }

    /// Smallest sidebar width when dragging its divider.
    private static let minPanelDividerPosition: CGFloat = 150
    /// Share of the sidebar height Places gets when Folders is shown below it.
    private static let placesShareOfSidebar: CGFloat = 0.55

    private var sidebarVisible: Bool { showPlaces || showFolders }
    private var rebuildingPanels = false

    /// Re-arranges the panel split views according to which panels are visible.
    func rebuildPanels() {
        // The split views pass through transient sizes while being rebuilt; don't remember those.
        rebuildingPanels = true
        defer { rebuildingPanels = false }
        for s in [outer, hSplit, vSplit, leftStack] {
            s.arrangedSubviews.forEach { s.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        if showPlaces { leftStack.addArrangedSubview(placesScroll) }
        if showFolders { leftStack.addArrangedSubview(folders) }
        if sidebarVisible {
            outer.addArrangedSubview(sidebar)
            sidebarMaterial.frame = sidebar.bounds
            layoutSidebar()
        }
        outer.addArrangedSubview(mainColumn)
        hSplit.addArrangedSubview(centerColumn)
        if showInformation { hSplit.addArrangedSubview(information) }
        vSplit.addArrangedSubview(hSplit)
        if showTerminal { vSplit.addArrangedSubview(terminal) }
        // Panels hold their size when the window resizes; the views take up the difference.
        for (i, v) in outer.arrangedSubviews.enumerated() { outer.setHoldingPriority(v === mainColumn ? .defaultLow : .init(270), forSubviewAt: i) }
        for (i, v) in hSplit.arrangedSubviews.enumerated() { hSplit.setHoldingPriority(v === centerColumn ? .defaultLow : .init(261), forSubviewAt: i) }
        for (i, v) in vSplit.arrangedSubviews.enumerated() { vSplit.setHoldingPriority(v === hSplit ? .defaultLow : .init(260), forSubviewAt: i) }
        layoutRoot()
        outer.layoutSubtreeIfNeeded()
        // Newly added panels arrive with empty frames; give every split its full extent before placing dividers
        // (setPosition only moves space between neighbours, so two zero-sized neighbours would stay at zero).
        for split in [outer, hSplit, vSplit] { split.adjustSubviews() }
        if sidebarVisible { outer.setPosition(PanelSize.sidebarWidth.fitted(in: outer.bounds.width, divider: outer.dividerThickness), ofDividerAt: 0) }
        mainColumn.layoutSubtreeIfNeeded()
        vSplit.layoutSubtreeIfNeeded()
        if showInformation {
            let w = hSplit.bounds.width, d = hSplit.dividerThickness
            hSplit.setPosition(w - PanelSize.informationWidth.fitted(in: w, divider: d) - d, ofDividerAt: 0)
        }
        if showTerminal {
            let h = vSplit.bounds.height, d = vSplit.dividerThickness
            vSplit.setPosition(h - PanelSize.terminalHeight.fitted(in: h, divider: d) - d, ofDividerAt: 0)
        }
        if showPlaces && showFolders { leftStack.setPosition(leftStack.bounds.height * Self.placesShareOfSidebar, ofDividerAt: 0) }
        for t in tabs { t.navigators.forEach { $0.showPlacesButton = !showPlaces } }
        if tabs.indices.contains(current) {
            if showFolders { folders.currentURL = view.url }
            if showInformation { information.show(hovered: nil, container: view) }
            if showTerminal { terminal.follow(view.url) }
        }
        Settings.store.set(showPlaces, forKey: "panel.places")
        Settings.store.set(showFolders, forKey: "panel.folders")
        Settings.store.set(showInformation, forKey: "panel.info")
        Settings.store.set(showTerminal, forKey: "panel.terminal")
        alignNavigators()
    }

    enum PanelSlot { case sidebar, information, terminal }
    private var animatingPanels = false
    private let panelAnimator = Animator()
    /// What to do when the running panel slide ends (apply a hide); also run when another slide interrupts it.
    private var pendingSlideCompletion: (() -> Void)?

    /// Shows or hides a panel with a slide (macOS-style), then rebuilds the layout.
    /// `toggle` flips the visibility flag(s); a sidebar change that keeps the sidebar visible just rebuilds.
    func animatePanel(_ slot: PanelSlot, show: Bool, toggle: @escaping () -> Void) {
        finishPanelSlide()
        if slot == .sidebar {
            let sidebarWasVisible = sidebarVisible
            toggle()
            if sidebarWasVisible == sidebarVisible { rebuildPanels(); return }
            if sidebarVisible { rebuildPanels(); slide(slot, opening: true) } else {
                // Put the flag back while sliding out, then apply.
                toggle(); slide(slot, opening: false) { toggle(); self.rebuildPanels() }
            }
            return
        }
        if show { toggle(); rebuildPanels(); slide(slot, opening: true) }
        else { slide(slot, opening: false) { toggle(); self.rebuildPanels() } }
    }

    /// Ends the running panel slide at once, applying what it was going to apply.
    private func finishPanelSlide() {
        panelAnimator.stop()
        animatingPanels = false
        let completion = pendingSlideCompletion
        pendingSlideCompletion = nil
        completion?()
    }

    /// Places/Folders sit below the title bar area; the strip above them (with the traffic lights) drags the window.
    func layoutSidebar() {
        let th = window?.styleMask.contains(.fullScreen) == true ? 0 : Theme.toolbarHeight
        leftStack.frame = CGRect(x: 0, y: 0, width: sidebar.bounds.width, height: max(0, sidebar.bounds.height - th))
    }

    /// Animates the divider of `slot`'s split view between collapsed and the panel's remembered size.
    private func slide(_ slot: PanelSlot, opening: Bool, completion: (() -> Void)? = nil) {
        let split = slot == .terminal ? vSplit : (slot == .sidebar ? outer : hSplit)
        let count = split.arrangedSubviews.count
        guard count > 1 else { completion?(); return }
        split.layoutSubtreeIfNeeded()
        let d = split.dividerThickness
        let divider: Int, collapsed: CGFloat, open: CGFloat, current: CGFloat
        switch slot {
        case .terminal:
            divider = 0
            collapsed = split.bounds.height
            open = collapsed - PanelSize.terminalHeight.fitted(in: collapsed, divider: d) - d
            current = collapsed - split.arrangedSubviews[1].frame.height - d
        case .information:
            divider = count - 2
            collapsed = split.bounds.width
            open = collapsed - PanelSize.informationWidth.fitted(in: collapsed, divider: d) - d
            current = collapsed - split.arrangedSubviews[count - 1].frame.width - d
        case .sidebar:
            divider = 0
            collapsed = 0
            open = PanelSize.sidebarWidth.fitted(in: split.bounds.width, divider: d)
            current = split.arrangedSubviews[0].frame.width
        }
        let from = opening ? collapsed : current
        let target = opening ? open : collapsed
        animatingPanels = true
        pendingSlideCompletion = completion
        split.setPosition(from, ofDividerAt: divider)
        panelAnimator.run(duration: opening ? 0.22 : 0.18, curve: opening ? Animator.easeOutCubic : Animator.easeInCubic, step: { p in
            split.setPosition(from + (target - from) * CGFloat(p), ofDividerAt: divider)
        }, completion: { [weak self] in
            self?.finishPanelSlide()
        })
    }

    func splitViewDidResizeSubviews(_ n: Notification) {
        guard let sv = n.object as? NSSplitView, sv === hSplit || sv === vSplit || sv === outer else { return }
        let id = ObjectIdentifier(sv)
        let last = splitStates[id]
        let resized = last?.size != sv.bounds.size
        let moved = last?.panel != panelExtent(in: sv)
        if !animatingPanels && !rebuildingPanels && !fittingPanels {
            // The split itself changed size (window resize, a neighbouring panel moved): its panel keeps its size as
            // far as the files leave room. Its panel changed size in a split of the same size: the user dragged
            // the divider, so remember the new size. (Splits also report resizes in which nothing changed.)
            if resized { fitPanel(of: sv) } else if moved { savePanelSize(of: sv) }
        }
        splitStates[id] = (sv.bounds.size, panelExtent(in: sv))
        if sv === outer { layoutToolbar(); layoutSidebar() }
        alignNavigators()
    }

    /// Size of each panel split and of its panel when it last resized its subviews, to tell window resizes from
    /// divider drags.
    private var splitStates: [ObjectIdentifier: (size: CGSize, panel: CGFloat?)] = [:]
    private var fittingPanels = false

    /// Width (height for the terminal) of the panel held by `sv`, nil while it holds none.
    private func panelExtent(in sv: NSSplitView) -> CGFloat? {
        if sv === outer { return outer.arrangedSubviews.first === sidebar ? sidebar.frame.width : nil }
        if sv === hSplit { return hSplit.arrangedSubviews.last === information ? information.frame.width : nil }
        if sv === vSplit { return vSplit.arrangedSubviews.last === terminal ? terminal.frame.height : nil }
        return nil
    }

    /// For tests: frames of the panel splits' children.
    var debugSplitFrames: [String] {
        [outer, hSplit, vSplit].map { sv in
            "\(type(of: sv)) \(Int(sv.bounds.width))x\(Int(sv.bounds.height)): " + sv.arrangedSubviews.map { "\(type(of: $0))=\(Int($0.frame.minX)),\(Int($0.frame.width))x\(Int($0.frame.height))\($0.isHidden ? " hidden" : "")" }.joined(separator: " ")
        }
    }

    /// Gives `sv`'s panel the size it should have at the split's current size (`PanelSize.fitted`): its remembered
    /// size, smaller while the window is too small for it and the files, and back again when the window grows.
    /// Window setup lays the splits out while the window is still zero-sized, and only the files area follows
    /// later resizes, so without this a panel could stay at zero, swallow the files, or stay shrunk.
    private func fitPanel(of sv: NSSplitView) {
        fittingPanels = true
        defer { fittingPanels = false }
        let d = sv.dividerThickness
        if sv === outer, sidebarVisible, outer.arrangedSubviews.first === sidebar {
            let target = PanelSize.sidebarWidth.fitted(in: outer.bounds.width, divider: d)
            if abs(sidebar.frame.width - target) > 0.5 { outer.setPosition(target, ofDividerAt: 0) }
        } else if sv === hSplit, showInformation, hSplit.arrangedSubviews.last === information {
            let w = hSplit.bounds.width, target = PanelSize.informationWidth.fitted(in: w, divider: d)
            if abs(information.frame.width - target) > 0.5 { hSplit.setPosition(w - target - d, ofDividerAt: hSplit.arrangedSubviews.count - 2) }
        } else if sv === vSplit, showTerminal, vSplit.arrangedSubviews.last === terminal {
            let h = vSplit.bounds.height, target = PanelSize.terminalHeight.fitted(in: h, divider: d)
            if abs(terminal.frame.height - target) > 0.5 { vSplit.setPosition(h - target - d, ofDividerAt: vSplit.arrangedSubviews.count - 2) }
        }
    }

    private func savePanelSize(of sv: NSSplitView) {
        if sv === outer, sidebarVisible, outer.arrangedSubviews.first === sidebar {
            PanelSize.sidebarWidth.save(sidebar.frame.width, in: outer.bounds.width)
        } else if sv === hSplit, showInformation {
            PanelSize.informationWidth.save(information.frame.width, in: hSplit.bounds.width)
        } else if sv === vSplit, showTerminal {
            PanelSize.terminalHeight.save(terminal.frame.height, in: vSplit.bounds.height)
        }
    }

    /// Panels keep their size when the window resizes; only the views (and the panel splits holding them) adjust.
    /// The panel splits are framed by hand, so NSSplitView's proportional resizing applies, not holding priorities.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === mainColumn || view === centerColumn || view === hSplit
    }

    /// Divider drags stay within the sizes a panel may have (see `PanelSize.dividerRange`), so the files keep room
    /// and the dragged size is one that is remembered.
    private func dragRange(_ splitView: NSSplitView) -> ClosedRange<CGFloat>? {
        let d = splitView.dividerThickness
        if splitView === outer {
            let r = PanelSize.sidebarWidth.dividerRange(in: splitView.bounds.width, divider: d)
            let lo = min(max(r.lowerBound, Self.minPanelDividerPosition), r.upperBound)
            return lo...r.upperBound
        }
        if splitView === hSplit { return PanelSize.informationWidth.dividerRange(in: splitView.bounds.width, divider: d) }
        if splitView === vSplit { return PanelSize.terminalHeight.dividerRange(in: splitView.bounds.height, divider: d) }
        return nil
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if animatingPanels { return p }
        return dragRange(splitView).map { max(p, $0.lowerBound) } ?? p
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if animatingPanels { return p }
        return dragRange(splitView).map { min(p, $0.upperBound) } ?? p
    }

    // MARK: - Layout

    var tabBarVisible: Bool { tabs.count > 1 || Settings.shared.alwaysShowTabBar }

    func layoutRoot() {
        let b = root.bounds
        (window as? DolphinWindow)?.positionTrafficLights()
        tabBar.isHidden = !tabBarVisible
        centerColumn.needsLayout = true
        // Full-height sidebar: the split spans the whole window, under the (transparent) title bar.
        outer.frame = b
        layoutSidebar()
        layoutToolbar()
        if tabs.indices.contains(current) { tab.frame = tabHost.bounds }
        alignNavigators()
    }

    /// The toolbar lives inside the (enlarged) title bar, over the main column only; in full screen the title bar
    /// auto-hides, so it moves into the main column instead.
    func layoutToolbar() {
        let th = Theme.toolbarHeight
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        let sidebarShown = outer.arrangedSubviews.first === sidebar
        let x = sidebarShown ? mainColumn.frame.minX : 0
        // Without the sidebar, the toolbar starts at the window edge and must clear the traffic lights.
        toolbar.leftInset = sidebarShown ? 12 : (fullScreen ? 10 : 84)
        if !fullScreen, let titlebar = window?.standardWindowButton(.closeButton)?.superview {
            if toolbar.superview !== titlebar {
                toolbar.removeFromSuperview()
                titlebar.addSubview(toolbar, positioned: .below, relativeTo: nil)
            }
            toolbar.autoresizingMask = []
            toolbar.frame = CGRect(x: x, y: titlebar.bounds.height - th, width: max(0, titlebar.bounds.width - x), height: th)
        } else {
            if toolbar.superview !== mainColumn {
                toolbar.removeFromSuperview()
                mainColumn.addSubview(toolbar)
            }
            toolbar.frame = CGRect(x: 0, y: 0, width: mainColumn.bounds.width, height: th)
        }
        toolbar.needsLayout = true
    }

    func alignNavigators() {
        guard tabs.indices.contains(current) else { return }
        toolbar.navigatorViews = tab.isSplit ? tab.navigators : [tab.navigators[0]]
        toolbar.paneRanges = tab.isSplit ? tab.paneRanges : []
        toolbar.needsLayout = true
    }

    /// Places were added, removed or renamed: navigators, tab titles and the window title show them.
    private func placesChanged() {
        for t in tabs {
            for n in t.navigators {
                n.places = PlacesModel.shared.allEntries
                n.refresh()
            }
        }
        if tabs.indices.contains(current) { syncToActiveView() }
    }

    /// Every setting applies immediately to open windows (no restart needed). A nil `key` means every setting
    /// may have changed (Settings › Restore Defaults).
    private func settingsChanged(key: String? = nil) {
        let s = Settings.shared
        func changed(_ k: String) -> Bool { key == nil || key == k }
        for t in tabs {
            for n in t.navigators {
                n.places = PlacesModel.shared.allEntries
                n.refresh()
                if changed("editableUrl") {
                    if s.editableLocation && !n.isEditing && n.superview != nil { n.beginEditing(selectAll: false) }
                    if !s.editableLocation && n.isEditing { n.endEditing() }
                }
            }
            for c in t.containers {
                if changed("folderSize") || changed("folderDepth") { c.model.resetFolderSizes() }
                if changed("filterBar") { c.filterBar.isHidden = !s.showFilterBarOnStartup && c.filterBar.field.stringValue.isEmpty }
                c.statusBar.mode = s.statusBarMode
                c.needsLayout = true
            }
        }
        tabBar.needsLayout = true
        layoutRoot()
        updateTabBar()
        if tabs.indices.contains(current) {
            syncToActiveView()
            if showInformation { information.refresh() }
        }
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(url: URL, select: Bool = true, split: URL? = nil, afterCurrent: Bool = true) -> PorpoiseTab {
        let t = PorpoiseTab(url: url)
        t.primary.delegate = self
        for (i, n) in t.navigators.enumerated() {
            n.delegate = self
            n.places = PlacesModel.shared.allEntries
            n.showPlacesButton = !showPlaces
            n.url = i == 0 ? url : (split ?? url)
        }
        let at = (afterCurrent && !Settings.shared.openNewTabsAtEnd && !tabs.isEmpty) ? current + 1 : tabs.count
        tabs.insert(t, at: at)
        if let s = split { t.openSplit(url: s, animated: false); t.setActive(secondary: false) }
        if select { showTab(at) } else { if at <= current && tabs.count > 1 { current += 1 }; updateTabBar() }
        return t
    }

    func showTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        tabHost.subviews.forEach { $0.removeFromSuperview() }
        current = i
        let t = tabs[i]
        t.frame = tabHost.bounds
        t.autoresizingMask = [.width, .height]
        tabHost.addSubview(t)
        updateTabBar()
        layoutRoot()
        syncToActiveView()
        window?.makeFirstResponder(view.list)
    }

    func updateTabBar() {
        tabBar.titles = tabs.map(\.title)
        tabBar.icons = tabs.map(\.iconName)
        tabBar.selected = current
        tabBar.isHidden = !tabBarVisible
        centerColumn.needsLayout = true
        root.needsLayout = true
    }

    func closeTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        rememberClosed(tabs.remove(at: i))
        if current >= tabs.count { current = tabs.count - 1 } else if i < current { current -= 1 }
        showTab(current)
    }

    /// Recently closed tabs kept for Undo Close Tab.
    private static let maxClosedTabs = 10

    private func rememberClosed(_ t: PorpoiseTab) {
        closedTabs.append((t.primary.url, t.secondary?.url))
        if closedTabs.count > Self.maxClosedTabs { closedTabs.removeFirst() }
    }

    /// Closes several tabs at once; the current tab stays selected if it survives, otherwise `fallback`.
    private func closeTabs(_ doomed: [PorpoiseTab], fallback: PorpoiseTab) {
        let wasCurrent = tab
        doomed.forEach(rememberClosed)
        tabs.removeAll { t in doomed.contains { $0 === t } }
        let selected = tabs.contains { $0 === wasCurrent } ? wasCurrent : fallback
        showTab(tabs.firstIndex { $0 === selected } ?? 0)
    }

    // MARK: - TabBarDelegate

    func tabBar(_ bar: TabBarView, select index: Int) { showTab(index) }
    func tabBar(_ bar: TabBarView, close index: Int) { closeTab(index) }
    func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?) {
        addTab(url: index.map { tabs[$0].active.url } ?? Settings.shared.homeURL)
    }
    func tabBar(_ bar: TabBarView, move from: Int, to: Int) {
        let wasCurrent = tab
        tabs.insert(tabs.remove(at: from), at: to)
        current = tabs.firstIndex { $0 === wasCurrent } ?? to
        updateTabBar()
    }
    func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int) {
        FileOperationsController.shared.handleDrop(urls, onto: tabs[index].active.url, operation: .generic, in: tabBar)
    }
    func tabBar(_ bar: TabBarView, detach index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let wasCurrent = tab
        let t = tabs.remove(at: index)
        AppDelegate.shared.newWindow(at: t.primary.url, split: t.secondary?.url)
        showTab(tabs.firstIndex { $0 === wasCurrent } ?? min(index, tabs.count - 1))
    }
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ icon: String, _ sel: Selector) {
            let it = m.addItem(withTitle: t, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = index
            it.image = Icons.shared.menuIcon(icon)
        }
        add("New Tab", "tab-new", #selector(tabMenuNew(_:)))
        add("Detach Tab", "tab-detach", #selector(tabMenuDetach(_:)))
        add("Rename Tab…", "edit-rename", #selector(tabMenuRename(_:)))
        m.addItem(.separator())
        add("Close Other Tabs", "tab-close-other", #selector(tabMenuCloseOthers(_:)))
        add("Close Tabs to the Left", "tab-close-other", #selector(tabMenuCloseLeft(_:)))
        add("Close Tabs to the Right", "tab-close-other", #selector(tabMenuCloseRight(_:)))
        add("Close Tab", "tab-close", #selector(tabMenuClose(_:)))
        return m
    }
    @objc private func tabMenuNew(_ s: NSMenuItem) { addTab(url: Settings.shared.homeURL) }
    @objc private func tabMenuDetach(_ s: NSMenuItem) { tabBar(tabBar, detach: s.tag) }
    @objc private func tabMenuClose(_ s: NSMenuItem) { closeTab(s.tag) }
    @objc private func tabMenuCloseOthers(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        let keep = tabs[s.tag]
        closeTabs(tabs.filter { $0 !== keep }, fallback: keep)
    }
    @objc private func tabMenuCloseLeft(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        closeTabs(Array(tabs[..<s.tag]), fallback: tabs[s.tag])
    }
    @objc private func tabMenuCloseRight(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        closeTabs(Array(tabs[(s.tag + 1)...]), fallback: tabs[s.tag])
    }
    @objc private func tabMenuRename(_ s: NSMenuItem) {
        let a = NSAlert()
        a.messageText = "Rename Tab"
        a.informativeText = "New tab name:"
        let f = NSTextField(string: tabs[s.tag].title)
        f.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            tabs[s.tag].customTitle = f.stringValue.isEmpty ? nil : f.stringValue
            updateTabBar()
        }
    }

    // MARK: - Active view sync

    /// Updates everything that mirrors the active view: navigator, toolbar, window title, panels.
    func syncToActiveView() {
        guard tabs.indices.contains(current) else { return }
        let t = tab
        t.navigators[0].url = t.primary.url
        if let s = t.secondary { t.navigators[1].url = s.url }
        let v = view
        toolbar.back.isEnabled = v.history.canGoBack
        toolbar.forward.isEnabled = v.history.canGoForward
        // Same rule as goUp(_:) and its menu item.
        toolbar.up.isEnabled = v.canGoUp
        toolbar.viewMode.iconName = v.model.props.mode.iconName
        updateSplitButton(for: t)
        toolbar.search.isToggled = !v.searchBar.isHidden
        toolbar.needsLayout = true
        places.currentURL = v.url
        window?.title = Settings.shared.showFullPathInTitle && v.url.isFileURL ? v.url.path
            : (PlacesModel.shared.title(for: v.url) ?? t.plainTitle)
        window?.representedURL = v.url.isFileURL ? v.url : nil
        updateTabBar()
        if showFolders { folders.currentURL = v.url }
        if showInformation { information.show(hovered: nil, container: v) }
        if showTerminal { terminal.follow(v.url) }
        alignNavigators()
    }

    /// Split button: "Split", or "Close" for the active side with the split menu (Dolphin's split action).
    private func updateSplitButton(for t: PorpoiseTab) {
        let b = toolbar.split
        b.isToggled = false
        b.showsMenuIndicator = t.isSplit
        b.isSplitButton = t.isSplit
        if t.isSplit {
            b.iconName = t.activeIsSecondary ? "view-right-close" : "view-left-close"
            b.title = "Close"
            b.toolTip = t.activeIsSecondary ? "Close right view" : "Close left view"
        } else {
            b.iconName = "view-split-left-right"
            b.title = "Split"
            b.toolTip = "Split view"
        }
    }

    // MARK: - ViewContainerDelegate

    func containerDidBecomeActive(_ c: ViewContainer) {
        guard tabs.indices.contains(current) else { return }
        if tab.secondary === c && !tab.activeIsSecondary { tab.setActive(secondary: true); syncToActiveView() }
        else if tab.primary === c && tab.activeIsSecondary { tab.setActive(secondary: false); syncToActiveView() }
    }

    func containerDidChangeURL(_ c: ViewContainer) {
        if c === view || tab.containers.contains(where: { $0 === c }) { syncToActiveView() }
        else if allContainers.contains(where: { $0 === c }) { updateTabBar() }   // a background tab's title
    }

    func containerSelectionChanged(_ c: ViewContainer) {
        if c === view, showInformation { information.show(hovered: nil, container: c) }
        if c === view, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) {
        // Finder aliases open their original (a folder alias browses into it).
        let items = items.map { it -> FileItem in
            guard Self.isAlias(it), let t = Self.resolvedTarget(of: it), let r = FileItem.load(t) else { return it }
            return r
        }
        // Finder Smart Folders open as live Spotlight results.
        if items.count == 1, items[0].url.pathExtension == "savedSearch", let u = URL(string: "smart://" + (items[0].url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")) {
            if inNewTab { addTab(url: u) } else { c.setURL(u) }
            return
        }
        // "Browse compressed files as folders": open archives like folders (an extracted, read-only copy).
        if Settings.shared.browseArchives, items.count == 1, items[0].url.isFileURL, ArchiveBrowser.isArchive(items[0]), !inNewTab {
            let archive = items[0]
            c.statusBar.showMessage("Opening “\(archive.name)”…")
            ArchiveBrowser.extractedFolder(for: archive) { result in
                switch result {
                case .success(let dir):
                    c.setURL(dir)
                    c.messageBar.show("Browsing the contents of “\(archive.name)”. This is a read-only copy; changes are not saved to the archive.", error: false)
                    c.needsLayout = true
                case .failure(let e): c.messageBar.show(e.localizedDescription, error: true); c.needsLayout = true
                }
            }
            return
        }
        let folders = items.filter(\.isBrowsableFolder)
        let files = items.filter { !$0.isBrowsableFolder }
        if folders.count + files.count > 10 && Settings.shared.confirmOpenMany {
            let a = NSAlert()
            a.messageText = "Are you sure you want to open \(items.count) items?"
            a.addButton(withTitle: "Open")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if folders.count == 1 && files.isEmpty && !inNewTab {
            c.setURL(folders[0].url)
        } else {
            for f in folders { addTab(url: f.url, select: false) }
        }
        if !files.isEmpty { openFiles(files) }
    }

    func openFiles(_ items: [FileItem]) {
        for it in items {
            if isExecutable(it) {
                // Settings › Confirmations › "When opening an executable file".
                switch Settings.shared.executableAction {
                case .run: ExternalTerminal.run(it.url); continue
                case .open: NSWorkspace.shared.open(it.url); continue
                case .ask:
                    let a = NSAlert()
                    a.messageText = "“\(it.name)” is an executable file. Do you want to run it, or open it in an application?"
                    a.addButton(withTitle: "Run")
                    a.addButton(withTitle: "Open")
                    a.addButton(withTitle: "Cancel")
                    switch a.runModal() {
                    case .alertFirstButtonReturn: ExternalTerminal.run(it.url)
                    case .alertSecondButtonReturn: NSWorkspace.shared.open(it.url)
                    default: break
                    }
                    continue
                }
            }
            if !it.url.isFileURL { RemoteOpener.open(it); continue }
            NSWorkspace.shared.open(it.url)
        }
    }

    /// Scripts and binaries with the executable bit (not apps/bundles).
    private func isExecutable(_ it: FileItem) -> Bool {
        guard it.url.isFileURL, !it.isDirectory, it.posixPermissions & 0o111 != 0, let t = it.utType else { return false }
        return t.conforms(to: .shellScript) || t.conforms(to: .unixExecutable) || t.conforms(to: .script)
    }

    func container(_ c: ViewContainer, menuFor item: FileItem?) -> NSMenu? { contextMenu(for: item, in: c) }

    func container(_ c: ViewContainer, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {
        FileOperationsController.shared.handleDrop(urls, onto: folder, operation: operation, in: c.list)
    }

    func container(_ c: ViewContainer, rename item: FileItem, to name: String) { rename(item, to: name, in: c) }

    func container(_ c: ViewContainer, middleClicked item: FileItem) {
        if item.isBrowsableFolder { addTab(url: item.url, select: false) }
        else if !item.url.isFileURL { RemoteOpener.open(item) }
        else {
            // Dolphin opens files with the second associated app on middle-click.
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            if apps.count > 1 { NSWorkspace.shared.open([item.url], withApplicationAt: apps[1], configuration: NSWorkspace.OpenConfiguration()) }
            else { NSWorkspace.shared.open(item.url) }
        }
    }

    /// Moves every view that shows something on `volume` to the home folder, so the volume can be ejected.
    static func leaveVolume(_ volume: URL) {
        let root = volume.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let home = FileManager.default.homeDirectoryForCurrentUser
        for w in AppDelegate.shared.windows {
            for t in w.tabs {
                for c in [t.primary, t.secondary].compactMap({ $0 }) where c.url.isFileURL {
                    let p = c.url.standardizedFileURL.path
                    if p == root || p.hasPrefix(prefix) { c.setURL(home) }
                }
            }
        }
    }

    func containerQuickLook(_ c: ViewContainer) { quickLook(nil) }
    func containerSearchVisibilityChanged(_ c: ViewContainer) { if c === view { toolbar.search.isToggled = !c.searchBar.isHidden } }

    func rename(_ item: FileItem, to name: String, in c: ViewContainer) {
        let old = item.url
        if let p = RemoteFS.provider(for: old) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try p.rename(old, to: name)
                    DispatchQueue.main.async { c.pendingSelect = old.deletingLastPathComponent().appendingPathComponent(name); c.reload() }
                } catch {
                    DispatchQueue.main.async { c.messageBar.show(error.localizedDescription, error: true); c.needsLayout = true }
                }
            }
            return
        }
        let newExt = (name as NSString).pathExtension
        if Settings.shared.confirmRenameType, !item.isBrowsableFolder, newExt.lowercased() != item.fileExtension.lowercased(), !item.fileExtension.isEmpty {
            let a = NSAlert()
            a.messageText = "Change File Type"
            a.informativeText = "Changing the file extension from “\(item.fileExtension)” to “\(newExt)” may change the way the file opens."
            a.addButton(withTitle: "Change Type")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if Settings.shared.confirmRenameHide, name.hasPrefix(".") && !item.name.hasPrefix(".") && !c.model.props.showHidden {
            let a = NSAlert()
            a.messageText = "Hide this File?"
            a.informativeText = "The name starts with a dot, so the item will be hidden."
            a.addButton(withTitle: "Rename and Hide")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let new = try FileActions.rename(old, to: name)
            FileOperationsController.shared.pushUndo(.renamed(from: old, to: new))
            c.pendingSelect = new
            c.reload()
        } catch where FileJob.isPermissionError(error) {
            // Root-owned item or folder: authenticate, as Finder does.
            let new = old.deletingLastPathComponent().appendingPathComponent(name)
            if FileOperationsController.authorize(verb: "rename", items: [old],
                                                  commands: FileOperationsController.renameCommands(old, to: new), window: window) {
                FileOperationsController.shared.pushUndo(.renamed(from: old, to: new))
                c.pendingSelect = new
            }
            c.reload()
        } catch {
            let a = NSAlert(error: error)
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
        }
    }

    // MARK: - BreadcrumbDelegate

    func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool) {
        let target: ViewContainer = (b === tab.navigators[1] ? tab.secondary : tab.primary) ?? view
        var isDir: ObjCBool = false
        if !url.isFileURL && !RemoteFS.isRemote(url) && !NetworkMounts.needsMount(url) && !Self.virtualSchemes.contains(url.scheme ?? "") {
            target.messageBar.show("Porpoise can't open “\(url.scheme ?? "")://” locations.", error: true)
            target.needsLayout = true
            return
        }
        if url.isFileURL && !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url); return }
            target.messageBar.show("The folder “\(url.path)” does not exist.", error: true)
            target.needsLayout = true
            return
        }
        if newTab { addTab(url: url, select: false) } else { target.setURL(url) }
        window?.makeFirstResponder(target.list)
    }

    /// Locations the app lists itself rather than a file system (Network, Recent, Tags, Smart Folders).
    private static let virtualSchemes: Set<String> = ["network", "recent", "tags", "smart"]

    func breadcrumbActivated(_ b: BreadcrumbView) {
        if tab.isSplit { tab.setActive(secondary: b === tab.navigators[1]); syncToActiveView() }
    }

    func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL) {
        FileOperationsController.shared.handleDrop(urls, onto: folder, operation: dropOperationForCurrentModifiers(), in: b)
    }

    // MARK: - PlacesPanelDelegate

    func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool) {
        if newTab { addTab(url: url, select: false); return }
        if splitView {
            if !tab.isSplit { tab.openSplit(url: url); tab.secondary?.delegate = self } else { tab.inactive?.setURL(url) }
            syncToActiveView()
            return
        }
        if view.url.standardizedFileURL == url.standardizedFileURL {
            // Clicking the current place again clears the filter (Dolphin).
            view.filterBarClosed(view.filterBar)
        }
        view.setURL(url)
        // Keyboard browsing in Places keeps focus there; clicks hand it to the view (in Applications: to the app
        // library, ready to type a search).
        let byKeyboard = NSApp.currentEvent?.type == .keyDown
        if !byKeyboard || window?.firstResponder !== p {
            window?.makeFirstResponder((view.showsApps ? view.apps?.grid : nil) ?? view.list)
        }
    }

    func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL) {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if url.standardizedFileURL == trash.standardizedFileURL {
            FileOperationsController.shared.trash(urls, window: window)
            return
        }
        FileOperationsController.shared.handleDrop(urls, onto: url, operation: dropOperationForCurrentModifiers(), in: places)
    }

    func places(_ p: PlacesPanel, emptyTrash: Void) { FileOperationsController.shared.emptyTrash(window: window) }
    func places(_ p: PlacesPanel, properties url: URL) { PropertiesWindow.show(urls: [url]) }
    func placesWantsViewFocus(_ p: PlacesPanel) { window?.makeFirstResponder(view.list) }

    // MARK: - Window

    func windowDidResize(_ notification: Notification) {
        (window as? DolphinWindow)?.positionTrafficLights()
        alignNavigators()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { layoutRoot() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutRoot() }
    func windowDidBecomeKey(_ notification: Notification) {
        (window as? DolphinWindow)?.positionTrafficLights()
        allContainers.forEach { $0.list.needsDisplay = true }
    }
    func windowDidResignKey(_ notification: Notification) { allContainers.forEach { $0.list.needsDisplay = true } }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.count > 1 && Settings.shared.confirmCloseTabs {
            let a = NSAlert()
            a.messageText = "You have multiple tabs open in this window, are you sure you want to close it?"
            a.addButton(withTitle: "Close All Tabs")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do not ask again"
            let r = a.runModal()
            if a.suppressionButton?.state == .on { Settings.shared.confirmCloseTabs = false }
            if r != .alertFirstButtonReturn { return false }
        }
        if showTerminal, terminal.hasRunningProgram, Settings.shared.confirmCloseTerminal {
            let a = NSAlert()
            a.messageText = "The program “\(terminal.runningProgramName)” is still running in the Terminal panel. Are you sure you want to close this window?"
            a.addButton(withTitle: "Close Window")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return false }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        AppDelegate.shared.saveSession()
        terminal.terminate()
        AppDelegate.shared.windowClosed(self)
    }

    // MARK: - Session

    var sessionState: [[String: String]] {
        tabs.map { t in
            var d = ["url": t.primary.url.absoluteString, "mode": t.primary.model.props.mode.rawValue]
            if let s = t.secondary { d["split"] = s.url.absoluteString }
            return d
        }
    }

    /// History menu for the Back/Forward dropdowns.
    func historyMenu(back: Bool) -> NSMenu {
        let m = NSMenu()
        let list = back ? view.history.backList : view.history.forwardList
        for (i, u) in list.prefix(15).enumerated() {
            let title = PlacesModel.shared.title(for: u) ?? (u.path == "/" ? "/" : u.lastPathComponent)
            let it = m.addItem(withTitle: title, action: #selector(historyJump(_:)), keyEquivalent: "")
            it.target = self
            it.tag = back ? -(i + 1) : (i + 1)
            it.image = Icons.shared.menuIcon(u.isFileURL ? Icons.folderIconName(u) : "document-open-recent")
            it.toolTip = u.path
        }
        return m
    }

    @objc private func historyJump(_ s: NSMenuItem) {
        if s.tag < 0 { view.goBack(-s.tag) } else { view.goForward(s.tag) }
    }
}

/// Current modifier keys mapped to a drop operation (for drops onto non-view targets).
private func dropOperationForCurrentModifiers() -> NSDragOperation {
    let m = NSEvent.modifierFlags
    if m.contains(.command) && m.contains(.option) { return .link }
    if m.contains(.option) { return .copy }
    if m.contains(.command) { return .move }
    return .generic
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
