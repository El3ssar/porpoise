import AppKit
import PorpoiseCore
import PorpoiseServices

protocol ViewContainerDelegate: AnyObject {
    func containerDidBecomeActive(_ c: ViewContainer)
    func containerDidChangeURL(_ c: ViewContainer)
    func containerSelectionChanged(_ c: ViewContainer)
    func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool)
    func container(_ c: ViewContainer, menuFor item: FileItem?) -> NSMenu?
    func container(_ c: ViewContainer, drop urls: [URL], onto folder: URL, operation: NSDragOperation)
    func container(_ c: ViewContainer, rename item: FileItem, to name: String)
    func container(_ c: ViewContainer, middleClicked item: FileItem)
    func containerQuickLook(_ c: ViewContainer)
    /// The search bar was shown or hidden (the toolbar's Search button follows it).
    func containerSearchVisibilityChanged(_ c: ViewContainer)
}

/// Dolphin's DolphinViewContainer: one view with its history, filter bar, search bar and status bar.
final class ViewContainer: NSView, ItemListViewDelegate, FilterBarDelegate, SearchBarDelegate {
    weak var delegate: ViewContainerDelegate?
    let model: DirectoryModel
    let list: ItemListView
    let scroll = NSScrollView()
    let header = DetailsHeaderView()
    let statusBar = StatusBarView()
    let filterBar = FilterBar()
    let searchBar = SearchBar()
    let messageBar = MessageBar()
    let selectionTop = SelectionTopBar()
    let selectionBottom = SelectionBottomBar()
    var selectionMode = false {
        didSet {
            selectionTop.isHidden = !selectionMode
            selectionBottom.isHidden = !selectionMode
            list.selectionModeActive = selectionMode
            if !selectionMode { selectionTop.prompt = nil }
            needsLayout = true
        }
    }
    var history: NavigationHistory
    var isActive = true {
        didSet {
            list.isActiveView = isActive
            needsDisplay = true
        }
    }
    private var hoverItem: FileItem?
    private var searchQuery: SearchRunner?
    private var observers: [NSObjectProtocol] = []
    /// The list is laid out again only when its scroll view changes size (layout() also runs for status bar text).
    private var laidOutScrollSize: NSSize?
    /// Free space of the shown volume, re-read at most every few seconds (`updateStatus` runs on every hover).
    private var volumeSpace: (url: URL, read: Date, free: Int64, total: Int)?

    var url: URL { model.location }

    /// The Applications folder as an app library (created the first time it's shown).
    private(set) var apps: AppsView?
    var showsApps: Bool { AppLibrary.isActive(for: url) && !model.isSearching }

    init(url: URL) {
        model = DirectoryModel(location: url)
        list = ItemListView(model: model)
        history = NavigationHistory(start: url)
        super.init(frame: .zero)
        list.delegate = self
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.viewBackground
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.horizontalScrollElasticity = .automatic
        scroll.appearance = NSAppearance(named: .darkAqua)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        header.list = list
        filterBar.delegate = self
        filterBar.isHidden = !Settings.shared.showFilterBarOnStartup
        searchBar.delegate = self
        searchBar.isHidden = true
        messageBar.isHidden = true
        messageBar.onDismiss = { [weak self] in self?.needsLayout = true }
        statusBar.onZoom = { [weak self] level in
            self?.list.previewZoom(ZoomLevels.size(forContinuousLevel: level), commitAfter: 0.6)
        }
        statusBar.onZoomCommit = { [weak self] in self?.list.commitZoom() }
        statusBar.onDiskClick = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        }
        for v in [scroll, header, searchBar, messageBar, selectionTop, selectionBottom, filterBar, statusBar] as [NSView] { addSubview(v) }
        list.onZoomPreview = { [weak self] size in
            self?.statusBar.zoomLevel = ZoomLevels.continuousLevel(for: size)
        }
        selectionTop.isHidden = true
        selectionBottom.isHidden = true
        selectionTop.onExit = { [weak self] in self?.selectionMode = false }
        selectionBottom.actions = [
            ("Copy", "edit-copy", #selector(MainWindowController.copy(_:))),
            ("Cut", "edit-cut", #selector(MainWindowController.cut(_:))),
            ("Move to Trash", "user-trash", #selector(MainWindowController.moveToTrash(_:))),
            ("Rename", "edit-rename", #selector(MainWindowController.renameItem(_:))),
            ("Duplicate", "edit-duplicate", #selector(MainWindowController.duplicateItem(_:))),
            ("Copy Location", "edit-copy-path", #selector(MainWindowController.copyLocation(_:))),
            ("Properties", "document-properties", #selector(MainWindowController.properties(_:))),
        ]

        model.onChange = { [weak self] in self?.modelChanged() }
        model.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.list.needsDisplay = true
            self.apps?.grid.needsDisplay = true
            self.updateStatus()
            self.selectionBottom.enabled = !self.model.selection.isEmpty
            self.delegate?.containerSelectionChanged(self)
        }
        model.onPropsChanged = { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.layout()   // now: the Details header comes or goes, which resizes the scroll view
            self.list.relayout()
            // Keep the current item in view across mode changes (Dolphin does); a zoom keeps its own position.
            if !self.list.committingZoom {
                if let c = self.model.currentURL ?? self.model.selection.first, let i = self.model.index(of: c) {
                    self.list.scrollToItem(i)
                } else {
                    self.list.scroll(.zero)
                }
            }
            self.updateStatus()
        }
        model.onLoaded = { [weak self] in
            guard let self else { return }
            self.updateStatus()
            if let e = self.model.loadError {
                if self.model.blockedByPrivacy {
                    self.messageBar.show(e, error: false, action: "Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                } else {
                    self.messageBar.show(e, error: true)
                }
            }
            if let pos = self.pendingPosition {
                self.pendingPosition = nil
                self.list.scroll(pos.origin)
                if self.pendingSelect == nil, let c = pos.current, self.model.index(of: c) != nil { self.model.currentURL = c }
            }
            if let u = self.pendingSelect, let i = self.model.index(of: self.listedURL(matching: u)) {
                self.list.select(self.model.rows[i].item.url)
            }
            self.pendingSelect = nil
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            self.statusBar.mode = Settings.shared.statusBarMode
            self.needsLayout = true
            switch n.object as? String {
            // Restore Defaults (no key), common vs. per-folder style, media folders: show the style that now applies.
            case nil, "perFolder", "dynamicView": self.model.reloadProps()
            case "appLibraryView":
                if self.url.standardizedFileURL == AppLibrary.location {
                    self.model.filter = Settings.shared.appLibraryView ? NameFilter(text: self.apps?.field.stringValue ?? "") : self.filterBar.filter
                    self.model.reloadProps()
                    self.model.reload()
                }
            case "folderDepth": self.model.resetFolderSizes()
            case "expandable": if !Settings.shared.detailsExpandableFolders { self.model.collapseAll() }
            default: break
            }
            self.model.rebuild()
        })
        observers.append(center.addObserver(forName: StatusCenter.message, object: nil, queue: .main) { [weak self] n in
            guard let self, self.isActive, let text = n.object as? String else { return }
            if n.userInfo?["error"] != nil { self.messageBar.show(text, error: true); self.needsLayout = true }
            else { self.statusBar.showMessage(text) }
        })
        observers.append(center.addObserver(forName: NetworkBrowser.changed, object: nil, queue: .main) { [weak self] _ in
            if self?.url.scheme == "network" { self?.model.reload() }
        })
        observers.append(center.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, let paths = n.userInfo?["paths"] as? Set<String> else { return }
            let mine = [self.model.location.isFileURL ? self.model.location.standardizedFileURL.path : self.model.location.path] + self.model.expanded.map(\.path)
            let appRoots = self.showsApps ? AppLibrary.roots.map(\.path) : []
            if (mine + appRoots).contains(where: paths.contains) || self.model.isSearching { self.model.reload() }
        })
        statusBar.mode = Settings.shared.statusBarMode
        model.reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }

    /// Item to select once the folder has loaded (e.g. the folder we came from after "Up").
    var pendingSelect: URL?

    /// The listed URL for `u`, even when the paths differ by a symlink (/tmp vs /private/tmp): such an item is
    /// matched by name when its parent resolves to the shown folder.
    private func listedURL(matching u: URL) -> URL {
        if let i = model.index(of: u) { return model.rows[i].item.url }
        guard u.isFileURL, model.location.isFileURL,
              u.deletingLastPathComponent().resolvingSymlinksInPath() == model.location.resolvingSymlinksInPath() else { return u }
        return model.rows.first { $0.depth == 0 && $0.item.name == u.lastPathComponent }?.item.url ?? u
    }

    // MARK: Layout (Dolphin's grid rows: search, message, view, filter, status)

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        var bottom = bounds.height
        if !searchBar.isHidden {
            searchBar.frame = CGRect(x: 0, y: y, width: bounds.width, height: 40)
            y += 40
        }
        if !messageBar.isHidden {
            messageBar.frame = CGRect(x: 0, y: y, width: bounds.width, height: 38)
            y += 38
        }
        if selectionMode {
            selectionTop.frame = CGRect(x: 0, y: y, width: bounds.width, height: 38)
            y += 38
        }
        let statusMode = Settings.shared.statusBarMode
        if statusMode == .fullWidth {
            statusBar.isHidden = false
            statusBar.frame = CGRect(x: 0, y: bottom - StatusBarView.height, width: bounds.width, height: StatusBarView.height)
            bottom -= StatusBarView.height
        }
        if selectionMode {
            selectionBottom.frame = CGRect(x: 0, y: bottom - 40, width: bounds.width, height: 40)
            bottom -= 40
        }
        if !filterBar.isHidden {
            filterBar.frame = CGRect(x: 0, y: bottom - 38, width: bounds.width, height: 38)
            bottom -= 38
        }
        // Applications: the app library takes the place of the list (and of the filter bar: it has its own search).
        if showsApps {
            if apps == nil {
                let a = AppsView(model: model)
                a.host = self
                addSubview(a, positioned: .above, relativeTo: scroll)
                apps = a
            }
            // Hiding the focused list would hand focus to the next view (Places): give it to the grid instead.
            let listHadFocus = window?.firstResponder === list
            apps?.isHidden = false
            scroll.isHidden = true
            header.isHidden = true
            if !filterBar.isHidden { bottom += 38; filterBar.frame.origin.y = bounds.height }
            apps?.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
            list.focusRedirect = apps?.grid
            if listHadFocus || window?.firstResponder === list { window?.makeFirstResponder(apps?.grid) }
            layoutStatusBar(bottom: bottom, mode: statusMode)
            return
        }
        let appsHadFocus = apps.map { a in window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: a) ?? false } ?? false } ?? false
        apps?.isHidden = true
        scroll.isHidden = false
        list.focusRedirect = nil
        if appsHadFocus { window?.makeFirstResponder(list) }
        let showHeader = model.props.mode == .details
        header.isHidden = !showHeader
        if showHeader {
            header.frame = CGRect(x: 0, y: y, width: bounds.width, height: ItemListView.headerHeight)
            y += ItemListView.headerHeight
        }
        scroll.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
        if scroll.frame.size != laidOutScrollSize {
            laidOutScrollSize = scroll.frame.size
            list.computeLayout()
        }
        header.needsDisplay = true
        layoutStatusBar(bottom: bottom, mode: statusMode)
    }

    /// The small (floating) and hidden status bar styles; the full-width one is laid out with the rows.
    private func layoutStatusBar(bottom: CGFloat, mode: StatusBarMode) {
        if mode == .small {
            let w = min(statusBar.smallWidth, bounds.width * 0.7)
            statusBar.isHidden = statusBar.displayText.isEmpty && statusBar.progress == nil
            statusBar.frame = CGRect(x: 0, y: bottom - 26, width: w, height: 26)
        } else if mode == .disabled {
            statusBar.isHidden = true
        }
    }

    @objc private func scrolled() {
        header.scrollX = scroll.contentView.bounds.minX
    }

    // MARK: Navigation

    func setURL(_ newURL: URL, addToHistory: Bool = true, selecting: URL? = nil) {
        // smb://, afp://, nfs://, webdav:// → let macOS mount the share, then browse the mount point.
        if NetworkMounts.needsMount(newURL) {
            statusBar.showMessage("Connecting to \(newURL.host ?? newURL.absoluteString)…")
            NetworkMounts.mount(newURL) { [weak self] result in
                switch result {
                case .success(let local): self?.setURL(local, addToHistory: addToHistory, selecting: selecting)
                case .failure(let e): self?.messageBar.show(e.localizedDescription, error: true); self?.needsLayout = true
                }
            }
            return
        }
        let u = newURL.isFileURL ? newURL.standardizedFileURL : newURL
        if !filterBar.isLocked { filterBar.clear(); if !Settings.shared.showFilterBarOnStartup { filterBar.isHidden = true } }
        if !searchBar.isHidden { closeSearch() }
        messageBar.isHidden = true
        if addToHistory { history.visit(u) }
        // Remember where the view was in the folder we leave, for Back/Forward.
        if u != url {
            viewPositions[url] = (list.visibleRect.origin, model.currentURL)
            if viewPositions.count > 200 { viewPositions.removeAll() }
            pendingPosition = nil
        }
        pendingSelect = selecting
        // The app library has its own search, which starts empty; elsewhere the filter bar's text applies.
        model.filter = AppLibrary.isActive(for: u) ? NameFilter() : filterBar.filter
        model.setLocation(u)
        list.scroll(.zero)
        if AppLibrary.isActive(for: u) { apps?.prepareForDisplay() }
        RecentLocations.shared.visit(u)
        needsLayout = true
        delegate?.containerDidChangeURL(self)
    }

    func goBack(_ steps: Int = 1) {
        let from = url
        guard let u = history.goBack(steps) else { return }
        setURL(u, addToHistory: false, selecting: from.deletingLastPathComponent() == u ? from : nil)
        pendingPosition = viewPositions[u]
    }

    func goForward(_ steps: Int = 1) {
        guard let u = history.goForward(steps) else { return }
        setURL(u, addToHistory: false)
        pendingPosition = viewPositions[u]
    }

    /// Scroll position and current item per visited folder (Dolphin restores both on Back/Forward).
    private var viewPositions: [URL: (origin: CGPoint, current: URL?)] = [:]
    /// Restored once the folder Back/Forward went to has loaded.
    private var pendingPosition: (origin: CGPoint, current: URL?)?

    /// Up works in local folders and on remote servers (sftp/ftp/adb) below their root; virtual lists have no parent.
    var canGoUp: Bool {
        guard url.isFileURL || RemoteFS.isRemote(url) else { return false }
        let path = url.path
        return !path.isEmpty && path != "/"
    }

    func goUp() {
        guard canGoUp else { return }
        setURL(url.deletingLastPathComponent(), selecting: url)
    }

    func reload() { model.reload() }

    // MARK: Status

    private func modelChanged() {
        if showsApps { apps?.reload() }
        list.relayout()
        list.refreshHover()
        updateStatus()
        needsLayout = true
    }

    func updateStatus() {
        if showsApps {
            // Apps, not files and bytes (bundle sizes would need a scan of every app).
            let n = model.rows.count, sel = model.selection.count
            let apps = { (k: Int) in k == 1 ? "1 app" : "\(k) apps" }
            statusBar.text = hoverItem.map { AppLibrary.displayName($0.url) }
                ?? (sel > 0 ? "\(apps(sel)) selected" : (model.isLoading && n == 0 ? "Loading apps…" : apps(n)))
        } else if let h = hoverItem {
            statusBar.text = "\(h.name) (\(h.typeDescription))"
        } else if !model.selection.isEmpty {
            let c = model.selectedCounts
            statusBar.text = FileFormat.summary(folders: c.folders, files: c.files, bytes: c.bytes, selected: true)
        } else {
            let c = model.visibleCounts
            statusBar.text = model.isLoading && model.rows.isEmpty ? "Loading folder…" : FileFormat.summary(folders: c.folders, files: c.files, bytes: c.bytes, selected: false)
        }
        statusBar.zoomLevel = ZoomLevels.continuousLevel(for: list.iconSize)
        if Settings.shared.statusBarMode == .fullWidth, let (free, total) = freeSpace() {
            statusBar.freeSpaceText = "\(FileFormat.size(free)) free"
            statusBar.usedFraction = 1 - Double(free) / Double(total)
            statusBar.toolTip = "\(FileFormat.size(free)) free out of \(FileFormat.size(Int64(total))) (\(Int(statusBar.usedFraction * 100))% used)"
        } else {
            statusBar.freeSpaceText = ""
            statusBar.toolTip = nil
        }
        needsLayout = true
    }

    /// Free and total bytes of the shown volume; a statfs per hover would be wasted work, so it is kept for a few seconds.
    private func freeSpace() -> (free: Int64, total: Int)? {
        guard url.isFileURL else { return nil }
        if let v = volumeSpace, v.url == url, Date().timeIntervalSince(v.read) < 5 { return (v.free, v.total) }
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 else {
            volumeSpace = nil
            return nil
        }
        volumeSpace = (url, Date(), free, total)
        return (free, total)
    }

    // MARK: Zoom / view mode

    func setZoom(_ level: Int) { list.animateZoom(to: ZoomLevels.iconSize(for: level)) }

    /// Cmd+= / Cmd+-: animate to Dolphin's next zoom step.
    func zoom(by delta: Int) { list.animateZoom(to: ZoomLevels.step(from: list.iconSize, by: delta)) }

    func setMode(_ m: ViewMode) {
        var p = model.props
        p.mode = m
        model.props = p
        model.saveProps()
        needsLayout = true
    }

    // MARK: Filter bar

    func showFilterBar() {
        if showsApps, let a = apps { window?.makeFirstResponder(a.field); return }
        filterBar.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        filterBar.focus()
    }

    func filterBar(_ bar: FilterBar, changed filter: NameFilter) { model.filter = filter }

    func filterBarClosed(_ bar: FilterBar) {
        bar.clear()
        bar.isHidden = true
        model.filter = NameFilter()
        needsLayout = true
        window?.makeFirstResponder(list)
    }

    // MARK: Search

    func showSearch() {
        if showsApps, let a = apps { window?.makeFirstResponder(a.field); return }
        guard url.isFileURL else {
            messageBar.show("Searching is available in local folders and mounted shares.", error: false)
            needsLayout = true
            return
        }
        searchBar.isHidden = false
        searchBar.scopeFolder = url
        delegate?.containerSearchVisibilityChanged(self)
        needsLayout = true
        layoutSubtreeIfNeeded()
        searchBar.focus()
    }

    func closeSearch() {
        searchQuery?.stop()
        searchQuery = nil
        searchBar.isHidden = true
        searchBar.clear()
        model.searchResults = nil
        model.endSearchView()
        needsLayout = true
        delegate?.containerSearchVisibilityChanged(self)
    }

    func searchBar(_ bar: SearchBar, search text: String, everywhere: Bool, contents: Bool) {
        searchQuery?.stop()
        guard !text.isEmpty else { model.searchResults = nil; return }
        let scope = everywhere ? FileManager.default.homeDirectoryForCurrentUser : url
        // Shown for the results only: never saved as the folder's style.
        model.showSearchView()
        statusBar.progress = 0.1
        model.searchResults = []
        searchQuery = SearchRunner(text: text, scope: scope, contents: contents) { [weak self] items, done in
            guard let self else { return }
            self.model.searchResults = items
            self.statusBar.progress = done ? nil : 0.5
            if done { self.statusBar.showMessage(items.isEmpty ? "No items found." : "\(items.count) items found.") }
        }
        searchQuery?.start()
    }

    func searchBarClosed(_ bar: SearchBar) {
        closeSearch()
        window?.makeFirstResponder(list)
    }

    // MARK: ItemListViewDelegate

    func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) { delegate?.container(self, open: items, inNewTab: inNewTab) }
    func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? { delegate?.container(self, menuFor: item) }
    func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {
        delegate?.container(self, drop: urls, onto: folder, operation: operation)
    }
    func itemList(_ view: ItemListView, rename item: FileItem, to name: String) { delegate?.container(self, rename: item, to: name) }
    func itemListDidBecomeActive(_ view: ItemListView) { delegate?.containerDidBecomeActive(self) }
    func itemList(_ view: ItemListView, hovered item: FileItem?) {
        hoverItem = item
        updateStatus()
        NotificationCenter.default.post(name: .hoverChanged, object: self, userInfo: item.map { ["url": $0.url] })
    }
    func itemListBackgroundDoubleClicked(_ view: ItemListView) {
        switch Settings.shared.doubleClickBackground {
        case .nothing: break
        case .selectAll: model.selection = Set(model.rows.map(\.item.url))
        case .goUp: goUp()
        case .newFolder: NSApp.sendAction(#selector(MainWindowController.createFolder(_:)), to: nil, from: self)
        case .toggleHidden: NSApp.sendAction(#selector(MainWindowController.toggleHiddenFiles(_:)), to: nil, from: self)
        case .openTerminal: NSApp.sendAction(#selector(MainWindowController.openTerminalHere(_:)), to: nil, from: self)
        }
    }
    func itemList(_ view: ItemListView, middleClicked item: FileItem) { delegate?.container(self, middleClicked: item) }
    func itemListQuickLook(_ view: ItemListView) { delegate?.containerQuickLook(self) }
}

extension Notification.Name {
    static let hoverChanged = Notification.Name("PorpoiseHoverChanged")
}

// MARK: - App library

extension ViewContainer: AppsViewHost {
    func appsViewDidBecomeActive(_ v: AppsView) { delegate?.containerDidBecomeActive(self) }
    func appsView(_ v: AppsView, open items: [FileItem]) { delegate?.container(self, open: items, inNewTab: false) }
    func appsView(_ v: AppsView, menuFor item: FileItem?) -> NSMenu? { delegate?.container(self, menuFor: item) }
    func appsViewQuickLook(_ v: AppsView) { delegate?.containerQuickLook(self) }
    func appsView(_ v: AppsView, hovered item: FileItem?) {
        hoverItem = item
        updateStatus()
    }
}
