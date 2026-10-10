import AppKit
import PorpoiseCore
import PorpoiseServices

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
    let sidebarMaterial = TintedMaterialView(material: .sidebar, alpha: 0.70)
    let placesScroll = NSScrollView()
    let places = PlacesPanel()
    lazy var folders = FoldersPanel()
    lazy var information = InformationPanel()
    lazy var terminal = TerminalPanel()

    // Changed only by the tab functions (MainWindowController+Tabs).
    var tabs: [PorpoiseTab] = []
    var current = 0
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

    // Panel layout state (see MainWindowController+Panels).
    var rebuildingPanels = false
    var animatingPanels = false
    let panelAnimator = Animator()
    /// What to do when the running panel slide ends (apply a hide); also run when another slide interrupts it.
    var pendingSlideCompletion: (() -> Void)?
    /// Size of each panel split and of its panel when it last resized its subviews, to tell window resizes from
    /// divider drags.
    var splitStates: [ObjectIdentifier: (size: CGSize, panel: CGFloat?)] = [:]
    var fittingPanels = false

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
    var allContainers: [ViewContainer] { tabs.flatMap(\.containers) }

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
            a.messageText = "Close this window with \(tabs.count) tabs open?"
            a.addButton(withTitle: "Close All Tabs")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don’t ask again"
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

    /// One entry per tab; the first also holds the window's frame and active tab.
    var sessionState: [[String: String]] {
        tabs.enumerated().map { i, t in
            var d = ["url": t.primary.url.absoluteString, "mode": t.primary.model.props.mode.rawValue]
            if let s = t.secondary { d["split"] = s.url.absoluteString }
            if i == 0, let w = window {
                d["frame"] = NSStringFromRect(w.frame)
                d["active"] = String(current)
            }
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
            it.image = Icons.shared.menuIcon(u.isFileURL ? IconTheme.folderIconName(u) : "document-open-recent")
            it.toolTip = u.path
        }
        return m
    }

    @objc private func historyJump(_ s: NSMenuItem) {
        if s.tag < 0 { view.goBack(-s.tag) } else { view.goForward(s.tag) }
    }
}

/// Current modifier keys mapped to a drop operation (for drops onto non-view targets).
