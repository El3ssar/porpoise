import AppKit
import PorpoiseCore
import PorpoiseFileSystem
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
    /// What the list says when it shows nothing: empty, still loading, or why it failed and what to do.
    let listState = ListStateView()
    /// The search that last finished failed, in its own words ("Nothing found" would be wrong then).
    private var searchError: String?
    /// Items the message bar says went to a cloud Trash (its Undo); Edit › Undo of them clears the message.
    var cloudTrashNotice: Set<URL> = []
    /// The account whose offline message shows (it goes, and the folder is read again, when the account is back).
    var offlineNotice: String?
    /// The cloud service's search running for the search bar (in a cloud folder).
    private(set) var cloudSearch: CloudSearch?
    var driveReloadPending = false
    /// A saved listing shows while the service is asked again, for long enough to say so ("Updating…"): a quick
    /// answer changes nothing in the status bar.
    private var showsUpdating = false
    private var refreshCheck: DispatchWorkItem?

    private func noteRefreshing() {
        refreshCheck?.cancel()
        guard model.isRefreshing else { showsUpdating = false; return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.model.isRefreshing else { return }
            self.showsUpdating = true
            self.updateStatus()
        }
        refreshCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check)
    }
    let selectionTop = SelectionTopBar()
    let selectionBottom = SelectionBottomBar()
    var preservesMissingLocation = false
    private(set) var historyTraversal = 0
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
            columnBrowser?.shareLook()
            needsDisplay = true
        }
    }
    /// Column view's columns, while the pane shows them (`ViewContainer+Columns`).
    var columnBrowser: ColumnBrowserView?
    /// Column view's →: the folder gone into selects its first item once it has listed.
    var selectsFirstOnLoad = false
    /// Split view: a 2 pt accent line along the top of the active pane, so which side keys and menus act on is plain
    /// at a glance (the tab sets it; one pane alone has none).
    var showsActiveEdge = false { didSet { activeEdge.isHidden = !showsActiveEdge } }
    private let activeEdge = NSView()
    private var hoverItem: FileItem?
    private var searchQuery: SearchRunner?
    private var observers: [NSObjectProtocol] = []
    /// The list is laid out again only when its scroll view changes size (layout() also runs for status bar text).
    private var laidOutScrollSize: NSSize?
    /// Free space of the shown volume, re-read at most every few seconds (`updateStatus` runs on every hover).
    private var volumeSpace: (url: URL, read: Date, free: Int64, total: Int)?
    /// The folder whose volume is being asked for its free space (in the background), if any.
    private var readingSpaceOf: URL?

    var url: URL { model.location }

    /// The Applications folder as an app library (created the first time it's shown).
    private(set) var apps: AppsView?
    var showsApps: Bool { AppLibrary.isActive(for: url) && !model.isSearching }
    /// What the zoom (slider, Cmd+= / Cmd+-, the View menu) acts on: the app library when it shows, else the list.
    var zoomView: ZoomableView { showsApps ? apps?.grid ?? list : list }

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        header.list = list
        filterBar.delegate = self
        filterBar.isHidden = !Settings.shared.showFilterBarOnStartup
        searchBar.delegate = self
        searchBar.isHidden = true
        messageBar.isHidden = true
        messageBar.onDismiss = { [weak self] in self?.needsLayout = true }
        statusBar.onZoom = { [weak self] level in
            self?.zoomView.previewZoom(ZoomLevels.size(forContinuousLevel: level), anchor: nil, commitAfter: 0.6)
        }
        statusBar.onZoomCommit = { [weak self] in self?.zoomView.commitZoom() }
        statusBar.onDiskClick = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(Self.storagePage(for: self.url))
        }
        for v in [scroll, listState, header, searchBar, messageBar, selectionTop, selectionBottom, filterBar, statusBar] as [NSView] {
            addSubview(v)
        }
        activeEdge.wantsLayer = true
        activeEdge.isHidden = true
        activeEdge.setAccessibilityElement(false)
        Theme.whenChanged(activeEdge) { [weak self] in self?.activeEdge.layer?.backgroundColor = Theme.accent.cgColor }
        addSubview(activeEdge)
        listState.isHidden = true
        listState.onAction = { [weak self] action in self?.perform(action) }
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
            ("Copy Location", "link", #selector(MainWindowController.copyLocation(_:))),
            ("Get Info", "document-properties", #selector(MainWindowController.properties(_:))),
        ]

        model.onChange = { [weak self] in self?.modelChanged() }
        model.onRemoteUpdate = { [weak self] apply in
            guard let self else { return apply() }
            self.animatingRemoteChange(apply)
        }
        model.onMetadataLoaded = { [weak self] in
            guard let self else { return }
            if self.model.props.roles(for: .compact).contains(.tags) { self.list.compactTextMeasurement = nil }
            // A Tags column or label sizes itself to the tags just read.
            if self.model.props.roles(for: self.model.props.mode).contains(.tags) { self.list.relayout() } else { self.list.needsDisplay = true }
        }
        model.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.list.needsDisplay = true
            self.list.accessibilitySelectionChanged()
            self.apps?.grid.needsDisplay = true
            self.updateStatus()
            self.selectionBottom.enabled = !self.model.selection.isEmpty
            self.columnBrowser?.syncAfter()
            self.delegate?.containerSelectionChanged(self)
        }
        model.onPropsChanged = { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.layout()  // now: the Details header comes or goes, which resizes the scroll view
            self.list.relayout()
            self.columnBrowser?.shareLook()
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
            self.list.transitions.itemsDelivered(loading: false)
            self.noteRefreshing()
            self.updateStatus()
            if let once = self.onNextLoad {
                self.onNextLoad = nil
                once()
            }
            // The folder shown was moved or deleted: go to the nearest one left, as Dolphin does.
            if self.model.locationVanished && !self.preservesMissingLocation {
                let gone = self.model.location
                self.setURL(DirectoryModel.nearestExisting(gone))
                self.messageBar.show("“\(gone.lastPathComponent)” was moved or deleted.", error: false)
                return
            }
            if PlacesModel.isCloud(self.model.location) {
                self.showCloudState()
            } else if let e = self.model.loadError {
                // With nothing listed, the list itself says what happened (`listState`); this is a failure after some.
                if !self.model.rows.isEmpty { self.messageBar.show(e, error: true) }
            } else if self.model.location.scheme == "network" {
                // Local Network is asked for here, at the first visit, rather than at first launch.
                SystemIntegration.FirstNeed.localNetwork { [weak self] in
                    self?.messageBar.show(
                        "Porpoise isn't allowed to look for servers on your network.", error: false, action: "Open Local Network Settings…"
                    ) { SystemIntegration.openPrivacyPane("Privacy_LocalNetwork") }
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
            if self.selectsFirstOnLoad {
                self.selectsFirstOnLoad = false
                if self.model.selection.isEmpty, let first = self.model.rows.first { self.list.select(first.item.url) }
            }
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
                self?.settingsChanged(key: n.object as? String)
            })
        observers.append(
            center.addObserver(forName: StatusCenter.message, object: nil, queue: .main) { [weak self] n in
                guard let self, self.isActive, let text = n.object as? String else { return }
                if n.userInfo?["error"] != nil {
                    self.messageBar.show(text, error: true); self.needsLayout = true
                } else {
                    self.statusBar.showMessage(text)
                }
            })
        observers.append(
            center.addObserver(forName: NetworkBrowser.changed, object: nil, queue: .main) { [weak self] _ in
                if self?.url.scheme == "network" { self?.model.reload() }
            })
        observers.append(
            center.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in self?.cloudAccountsChanged() })
        observers.append(
            center.addObserver(forName: CloudEditing.changed, object: nil, queue: .main) { [weak self] _ in
                guard let self, PlacesModel.isCloud(self.model.location) || self.model.isSearching else { return }
                self.list.needsDisplay = true
                self.updateStatus()
            })
        observers.append(
            center.addObserver(forName: CloudOfflineHub.changed, object: nil, queue: .main) { [weak self] _ in
                // Badges come from memory: a redraw shows the new states and progress.
                guard let self, PlacesModel.isCloud(self.model.location) || self.model.isSearching else { return }
                self.list.needsDisplay = true
                self.updateStatus()
            })
        observers.append(
            center.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) { [weak self] n in
                guard let self, let id = n.object as? String else { return }
                self.driveChanged(account: id)
            })
        observers.append(
            center.addObserver(forName: CloudAccounts.changeReverted, object: nil, queue: .main) { [weak self] n in
                guard let self, let urls = n.object as? [URL], !urls.isEmpty else { return }
                if !self.cloudTrashNotice.isEmpty, self.cloudTrashNotice == Set(urls) {
                    self.cloudTrashNotice = []
                    self.messageBar.dismiss()
                    // Back from the Trash: selected, as Finder does.
                    if n.userInfo?["kind"] as? String == "trashed" { self.pendingSelect = urls[0]; self.model.selection = Set(urls) }
                }
            })
        observers.append(
            center.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: .main) { [weak self] n in
                guard let self, let paths = n.userInfo?["paths"] as? Set<String> else { return }
                let mine = ([self.model.location] + Array(self.model.expanded)).map {
                    $0.isFileURL ? FilePath.canonical($0.path) : $0.path
                }
                let appRoots = self.showsApps ? AppLibrary.roots.map { FilePath.canonical($0.path) } : []
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
            u.deletingLastPathComponent().resolvingSymlinksInPath() == model.location.resolvingSymlinksInPath()
        else { return u }
        return model.rows.first { $0.depth == 0 && $0.item.name == u.lastPathComponent }?.item.url ?? u
    }

    // MARK: Layout (Dolphin's grid rows: search, message, view, filter, status)

    override func layout() {
        super.layout()
        activeEdge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2)
        if subviews.last !== activeEdge { addSubview(activeEdge, positioned: .above, relativeTo: nil) }
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
                a.grid.onZoomPreview = { [weak self] size in self?.statusBar.zoomLevel = ZoomLevels.continuousLevel(for: size) }
                addSubview(a, positioned: .above, relativeTo: scroll)
                apps = a
            }
            // Hiding the focused list would hand focus to the next view (Places): give it to the grid instead.
            let listHadFocus = window?.firstResponder === list
            layoutColumns(in: .zero)
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
        let viewFrame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
        layoutColumns(in: viewFrame)
        if columnBrowser == nil {
            scroll.frame = viewFrame
            listState.frame = viewFrame
        }
        if scroll.frame.size != laidOutScrollSize {
            laidOutScrollSize = scroll.frame.size
            list.transitions.resized()
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

    /// `restoring`: where the view was in `newURL` (Back/Forward). Set before loading: some locations (network:,
    /// recent:) load synchronously, and the position would otherwise wait for (and jump at) their next reload.
    func setURL(_ newURL: URL, addToHistory: Bool = true, selecting: URL? = nil, restoring position: ViewPosition? = nil) {
        // smb://, afp://, nfs://, webdav:// → let macOS mount the share, then browse the mount point.
        if NetworkMounts.needsMount(newURL) {
            statusBar.showMessage("Connecting to \(newURL.host ?? newURL.absoluteString)…")
            NetworkMounts.mount(newURL) { [weak self] result in
                switch result {
                case .success(let local): self?.setURL(local, addToHistory: addToHistory, selecting: selecting, restoring: position)
                case .failure(let e): self?.messageBar.show(e.localizedDescription, error: true); self?.needsLayout = true
                }
            }
            return
        }
        // A password typed into the address goes to the Keychain, never into the tab, its history or the session.
        let u = newURL.isFileURL ? newURL.standardizedFileURL : RemoteFS.storingPassword(newURL)
        if !filterBar.isLocked { filterBar.clear(); if !Settings.shared.showFilterBarOnStartup { filterBar.isHidden = true } }
        if !searchBar.isHidden { closeSearch() }
        messageBar.isHidden = true
        offlineNotice = nil
        if addToHistory { history.visit(u) }
        // Remember where the view was in the folder we leave, for Back/Forward.
        if u != url {
            viewPositions[url] = (list.visibleRect.origin, model.currentURL)
            if viewPositions.count > 200 { viewPositions.removeAll() }
            pendingPosition = nil
        }
        if let position { pendingPosition = position }
        pendingSelect = selecting
        // The app library has its own search, which starts empty; elsewhere the filter bar's text applies.
        model.filter = AppLibrary.isActive(for: u) ? NameFilter() : filterBar.filter
        list.scroll(.zero)  // first: a location that loads synchronously restores its position inside setLocation
        list.transitions.navigate()
        let lender = columnsWillNavigate(to: u)
        model.setLocation(u, takingListingOf: lender?.model)
        columnsDidNavigate(lender: lender, selecting: selecting)
        if AppLibrary.isActive(for: u) { apps?.prepareForDisplay() }
        RecentLocations.shared.visit(u)
        needsLayout = true
        delegate?.containerDidChangeURL(self)
    }

    func goBack(_ steps: Int = 1) {
        let from = url
        guard let u = history.goBack(steps) else { return }
        historyTraversal = -steps
        defer { historyTraversal = 0 }
        setURL(u, addToHistory: false, selecting: from.deletingLastPathComponent() == u ? from : nil, restoring: viewPositions[u])
    }

    func goForward(_ steps: Int = 1) {
        guard let u = history.goForward(steps) else { return }
        historyTraversal = steps
        defer { historyTraversal = 0 }
        setURL(u, addToHistory: false, restoring: viewPositions[u])
    }

    /// Scroll position and current item per visited folder (Dolphin restores both on Back/Forward).
    typealias ViewPosition = (origin: CGPoint, current: URL?)
    private var viewPositions: [URL: ViewPosition] = [:]
    /// Restored once the folder Back/Forward went to has loaded.
    private var pendingPosition: ViewPosition?

    /// Up works in local folders and on remote servers (sftp/ftp/adb) below their root; virtual lists have no parent.
    var canGoUp: Bool {
        LocationKind.of(url).canGoUp(from: url)
    }

    func goUp() {
        guard canGoUp else { return }
        setURL(url.deletingLastPathComponent(), selecting: url)
    }

    func reload() { model.reload() }

    /// Shows, over the list, what an empty list means; nothing while it lists items or the app library shows.
    func refreshListState() {
        guard !showsApps, model.rows.isEmpty else { return listState.show(nil) }
        let location = model.location
        if let e = model.loadError, !model.isSearching, !(model.isLoading && model.items.isEmpty) {
            let missing = location.isFileURL && !FileManager.default.fileExists(atPath: location.path)
            listState.show(
                LoadErrorPresentation.error(
                    e, location: location, missing: missing, blockedByPrivacy: model.blockedByPrivacy, cloud: PlacesModel.isCloud(location)))
        } else {
            let trash = location.isFileURL && (location.lastPathComponent == ".Trash" || location.path.contains("/.Trashes/"))
            listState.show(
                LoadErrorPresentation.empty(
                    loading: model.isLoading && model.items.isEmpty, searching: model.isSearching, searchError: searchError,
                    filtering: model.filter.isActive, trash: trash))
        }
    }

    private func perform(_ action: ListState.Action) {
        switch action {
        case .retry: reload()
        case .goUp:
            setURL(
                model.location.isFileURL
                    ? DirectoryModel.nearestExisting(model.location.deletingLastPathComponent()) : model.location.deletingLastPathComponent())
        case .openPrivacySettings:
            SystemIntegration.openPrivacyPane("Privacy_AllFiles")
        }
    }

    /// Keep unrelated preferences out of the listing/re-layout path, including panes in hidden tabs.
    private func settingsChanged(key: String?) {
        switch key {
        case nil:
            statusBar.mode = Settings.shared.statusBarMode
            apps?.grid.savedSizeChanged()
            model.reloadProps()
            model.rebuild()
            needsLayout = true
        case "perFolder", "dynamicView", "appearanceIconSizes": model.reloadProps()
        case "appLibraryIconSize": apps?.grid.savedSizeChanged()
        case "appLibraryView":
            guard url.standardizedFileURL == AppLibrary.location else { return }
            model.filter = Settings.shared.appLibraryView ? NameFilter(text: apps?.field.stringValue ?? "") : filterBar.filter
            model.reloadProps()
            model.reload()
        case "sorting", "hideBackup": model.rebuild()
        case "folderDepth", "folderSize":
            model.resetFolderSizes()
            model.rebuild()
        case "expandable":
            if !Settings.shared.detailsExpandableFolders { model.collapseAll() }
        case "binaryUnits":
            updateStatus()
        case "statusBar2", "zoomSlider2":
            statusBar.mode = Settings.shared.statusBarMode
            updateStatus()
        default: break
        }
    }

    // MARK: Status

    /// Called once, after the next load finishes (the split view flies items in when the new pane has them).
    var onNextLoad: (() -> Void)?

    /// The width the list gets in a pane `paneWidth` wide (the pane minus what's beside the list, such as a panel).
    func listWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        let beside = bounds.width > 0 ? bounds.width - list.visibleWidth : 0
        return max(100, paneWidth - beside)
    }

    private func modelChanged() {
        // Folder counts can arrive without replacing rows; a Size label may have become wider.
        if !list.committingZoom, model.props.roles(for: .compact).contains(.size) { list.compactTextMeasurement = nil }
        if showsApps { apps?.reload() }
        list.relayout()
        list.transitions.itemsDelivered(loading: model.isLoading)
        list.refreshHover()
        updateStatus()
        needsLayout = true
    }

    func updateStatus() {
        refreshListState()
        if showsApps {
            // Apps, not files and bytes (bundle sizes would need a scan of every app).
            let n = model.rows.count, sel = model.selection.count
            let apps = { (k: Int) in k == 1 ? "1 app" : "\(k) apps" }
            statusBar.text =
                hoverItem.map { AppLibrary.displayName($0.url) }
                ?? (sel > 0 ? "\(apps(sel)) selected" : (model.isLoading && n == 0 ? "Loading apps…" : apps(n)))
        } else if let h = hoverItem {
            statusBar.text = "\(h.name) (\(h.typeDescription))" + (h.isWebDocument ? " · opens in your browser" : "")
        } else if !model.selection.isEmpty {
            let c = model.selectedCounts
            statusBar.text = FileFormat.summary(folders: c.folders, files: c.files, bytes: c.bytes, selected: true)
        } else {
            let c = model.visibleCounts
            let summary = FileFormat.summary(folders: c.folders, files: c.files, bytes: c.bytes, selected: false)
            statusBar.text =
                model.isLoading && model.rows.isEmpty
                ? "Loading folder…" : summary.isEmpty ? (model.loadError == nil ? FileFormat.itemCount(0) : listState.state?.title ?? "") : summary
        }
        statusBar.zoomLevel = ZoomLevels.continuousLevel(for: zoomView.iconSize)
        if PlacesModel.isCloud(url) {
            // The folder's sharing role decides whether it can be changed, and the account's storage replaces a disk's.
            let readOnly = CloudAccounts.shared.denial(.addItems, folder: url)
            // A file open in another app says how its saves are doing.
            let pointed = hoverItem ?? (model.selection.count == 1 ? model.selectedItems.first : nil)
            if let pointed, let edit = list.editMark(pointed) {
                statusBar.text = "\(pointed.name) · " + edit.note(CloudAccounts.shared.providerTitle(for: url))
            } else if let pointed, case let state = model.cloud(for: pointed).state, state != .local, state != .cloudOnly {
                // Kept, downloading, a problem: what the badge means.
                statusBar.text = "\(pointed.name) · " + state.help
            }
            if showsUpdating, model.isRefreshing, hoverItem == nil, model.selection.isEmpty {
                statusBar.text = statusBar.text.isEmpty ? "Updating…" : statusBar.text + " · Updating…"
            }
            if readOnly != nil, !(hoverItem?.isWebDocument ?? false) {
                // Offline is a passing state, not the folder's sharing role.
                let what = CloudAccounts.shared.account(for: url)?.status == .offline ? "Offline" : "View only"
                statusBar.text = statusBar.text.isEmpty ? what : statusBar.text + " · " + what
            }
            let account = CloudAccounts.shared.account(for: url)
            if Settings.shared.statusBarMode == .fullWidth, let used = account?.quotaUsed, let total = account?.quotaTotal, total > 0 {
                statusBar.freeSpaceText = QuotaBar.text(used: used, total: total)
                statusBar.usedFraction = Double(used) / Double(total)
            } else {
                statusBar.freeSpaceText = ""
            }
            statusBar.toolTip = readOnly
        } else if Settings.shared.statusBarMode == .fullWidth, let (free, total) = freeSpace() {
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
        let known = volumeSpace.flatMap { $0.url == url ? ($0.free, $0.total) : nil }
        if let v = volumeSpace, v.url == url, Date().timeIntervalSince(v.read) < 5 { return known }
        // Asking the volume can take tens of milliseconds (more on a network share): it's done in the background, and
        // what was known shows meanwhile.
        if readingSpaceOf != url {
            readingSpaceOf = url
            let folder = url
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // URL copies share cached resource values; our five-second cache must not renew stale capacity.
                var freshFolder = folder
                freshFolder.removeCachedResourceValue(forKey: .volumeAvailableCapacityKey)
                freshFolder.removeCachedResourceValue(forKey: .volumeTotalCapacityKey)
                // Match Finder Get Info's Available figure, rather than adding reclaimable "important usage" space.
                let v = try? freshFolder.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                DispatchQueue.main.async {
                    guard let self, self.readingSpaceOf == folder else { return }
                    self.readingSpaceOf = nil
                    if let free = v?.volumeAvailableCapacity, let total = v?.volumeTotalCapacity, total > 0 {
                        self.volumeSpace = (folder, Date(), Int64(free), total)
                    } else {
                        self.volumeSpace = nil
                    }
                    if folder == self.url { self.updateStatus() }
                }
            }
        }
        return known
    }

    // MARK: Zoom / view mode

    func setZoom(_ level: Int) { zoomView.animateZoom(to: ZoomLevels.iconSize(for: level)) }

    /// Cmd+= / Cmd+-: animate to Dolphin's next zoom step.
    func zoom(by delta: Int) { zoomView.animateZoom(to: ZoomLevels.step(from: zoomView.iconSize, by: delta)) }

    /// The zoom level shown in menus (the app library's own size when it shows).
    var zoomLevel: Int { showsApps ? ZoomLevels.nearestLevel(for: zoomView.iconSize) : model.props.zoomLevel(for: model.props.mode) }

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

    func filterBar(_ bar: FilterBar, changed filter: NameFilter) { animatingItems { model.filter = filter } }

    /// Applies a change to what's listed (filter, search results), the items gliding to their new places, the ones
    /// that went away fading out and new ones growing in.
    /// `onlyAdding`: the change only adds items (the same search's next results), so no pictures are needed.
    private func animatingItems(searchStyle: Bool = false, onlyAdding: Bool = false, _ change: () -> Void) {
        guard !showsApps else { return change() }
        if searchStyle {
            list.transitions.change(.search, duration: 0.45, curve: Animator.easeInOutCubic, cascade: true, pictures: !onlyAdding, change)
        } else {
            list.transitions.change(.filter, pictures: !onlyAdding, change)
        }
    }

    /// A change made elsewhere (in the browser, on another device): rows appear, rename or vanish in place, quietly.
    /// The selection stays, and so does what's on screen: the first item in view keeps its place when rows come or go
    /// above it.
    func animatingRemoteChange(_ change: () -> Void) {
        guard !showsApps else { return change() }
        let list = self.list
        let top = list.visibleRect.minY > 1 ? list.candidateIndexes(in: list.visibleRect).min() : nil
        let anchor = top.map { (key: list.key(ofRow: $0), offset: list.frames[$0].minY - list.visibleRect.minY) }
        list.transitions.change(.remote, duration: 0.35) {
            change()
            list.computeLayout()
            if let anchor, let i = list.row(forKey: anchor.key) {
                let y = list.frames[i].minY - anchor.offset
                if abs(y - list.visibleRect.minY) > 0.5 { list.scroll(CGPoint(x: list.visibleRect.minX, y: max(0, y))) }
            }
        }
    }

    func filterBarClosed(_ bar: FilterBar) {
        bar.clear()
        bar.isHidden = true
        animatingItems { model.filter = NameFilter() }
        needsLayout = true
        window?.makeFirstResponder(list)
    }

    /// What the capacity bar opens: in a cloud folder its account's storage page (the bar shows that quota), else
    /// macOS's Storage settings.
    static func storagePage(for url: URL) -> URL {
        if let account = CloudAccounts.shared.account(for: url), let page = account.provider.descriptor.storageURL {
            return AccountActions.webLink(page, account: account)
        }
        return URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
    }

    // MARK: Search

    func showSearch() {
        if showsApps, let a = apps { window?.makeFirstResponder(a.field); return }
        let cloud = PlacesModel.isCloud(url)
        guard url.isFileURL || cloud else {
            messageBar.show("Searching is available in local folders, mounted shares and cloud accounts.", error: false)
            needsLayout = true
            return
        }
        searchBar.isHidden = false
        searchBar.cloudService = cloud ? CloudAccounts.shared.providerTitle(for: url) : nil
        searchBar.scopeFolder = url
        delegate?.containerSearchVisibilityChanged(self)
        needsLayout = true
        layoutSubtreeIfNeeded()
        searchBar.focus()
    }

    func closeSearch() {
        searchQuery?.stop()
        searchQuery = nil
        cloudSearch?.stop()
        cloudSearch = nil
        statusBar.progress = nil
        searchBar.isHidden = true
        searchBar.clear()
        animatingItems(searchStyle: true) {
            model.searchMatches = nil
            model.searchResults = nil
            model.endSearchView()
        }
        needsLayout = true
        delegate?.containerSearchVisibilityChanged(self)
    }

    func searchBar(_ bar: SearchBar, search text: String, everywhere: Bool, contents: Bool) {
        searchQuery?.stop()
        cloudSearch?.stop()
        cloudSearch = nil
        if bar.cloudService != nil, !text.isEmpty { return searchCloud(text, everywhere: everywhere, contents: contents) }
        guard !text.isEmpty else {
            statusBar.progress = nil
            animatingItems(searchStyle: true) {
                model.searchMatches = nil
                model.searchResults = nil
                model.endSearchView()
            }
            return
        }
        let scope = everywhere ? FileManager.default.homeDirectoryForCurrentUser : url
        statusBar.progress = 0.1
        searchError = nil
        // What's shown stays until results come (the folder, or the previous results); then it all morphs at once,
        // like the split view: what still matches glides to its place among the results, the rest fades out, and
        // the new results come in one after another.
        searchQuery = SearchRunner(text: text, scope: scope, contents: contents, everywhere: everywhere) { [weak self] items, done in
            // "Nothing yet" while searching changes nothing: what's shown stays until there are results to morph to.
            guard let self, done || !items.isEmpty, let runner = self.searchQuery else { return }
            let matches = SearchMatches(
                text: text, contents: contents, snippets: runner.snippets, snippetsMarkContentMatches: runner.snippetsMarkContentMatches)
            // Sorted off the main thread: typing and scrolling stay smooth with thousands of results.
            self.model.sortSearchResults(items) { [weak self] apply in
                guard let self, self.searchQuery === runner else { return }
                // The same search's next batch keeps what's shown and adds to it.
                let old = self.model.searchResults ?? []
                let adding =
                    self.model.isSearching && !old.isEmpty && items.count >= old.count
                    && old.indices.allSatisfy { items[$0].url == old[$0].url }
                self.animatingItems(searchStyle: true, onlyAdding: adding) {
                    // Shown for the results only: never saved as the folder's style.
                    if !self.model.isSearching { self.model.showSearchView() }
                    self.model.searchMatches = matches
                    apply()
                }
            }
            self.statusBar.progress = done ? nil : 0.5
            if done {
                let result = items.isEmpty ? "No items found." : "\(FileFormat.itemCount(items.count)) found."
                self.searchError = runner.queryError
                self.statusBar.showMessage(runner.queryError ?? (result + " · " + SearchIndex.shared.statusText))
                self.refreshListState()
            }
        }
        searchQuery?.start()
    }

    /// The cloud service's own search: "Searching Google Drive…" while its pages come in, the results growing as
    /// they do (what's shown stays until the first ones), then how many were found there.
    private func searchCloud(_ text: String, everywhere: Bool, contents: Bool) {
        let run = CloudSearch(text, in: url, everywhere: everywhere, contents: contents)
        cloudSearch = run
        statusBar.progress = 0.1
        statusBar.showMessage("Searching \(run.serviceTitle)…", duration: 600)
        run.onResults = { [weak self] items, done in
            guard let self, self.cloudSearch === run else { return }
            if done {
                self.statusBar.progress = nil
                self.statusBar.showMessage(run.summary)
                if run.error != nil, items.isEmpty, (run.error as? CloudEditError) != .notSupported {
                    self.messageBar.show(run.summary, error: true)
                    self.needsLayout = true
                }
            } else {
                self.statusBar.progress = 0.5
            }
            guard done || !items.isEmpty else { return }
            let matches = SearchMatches(text: text, contents: contents)
            self.model.sortSearchResults(items) { [weak self] apply in
                guard let self, self.cloudSearch === run else { return }
                let old = self.model.searchResults ?? []
                let adding =
                    self.model.isSearching && !old.isEmpty && items.count >= old.count
                    && old.indices.allSatisfy { items[$0].url == old[$0].url }
                self.animatingItems(searchStyle: true, onlyAdding: adding) {
                    if !self.model.isSearching { self.model.showSearchView() }
                    self.model.searchMatches = matches
                    apply()
                }
            }
        }
        run.start()
    }

    func searchBar(_ bar: SearchBar, hint: String?) {
        if let hint { statusBar.showMessage(hint) }
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

extension ItemListView: ZoomableView {
    var glideProgress: CGFloat? { transition?.progress }
}
extension AppsGridView: ZoomableView {}

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
