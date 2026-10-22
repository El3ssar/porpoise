import AppKit
import PorpoiseCore
import PorpoiseServices

/// Dolphin's Folders panel (F7): a folder tree that follows the current location.
final class FoldersPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = FolderOutlineView()
    private let scroll = NSScrollView()
    private var remoteTree: RemoteFolderTree?
    private var root: Node
    var onNavigate: ((URL, Bool) -> Void)?
    var currentURL: URL? { didSet { if currentURL != oldValue { followCurrent() } } }
    private var settingsObserver: NSObjectProtocol?
    private var ancestryObservers: [NSObjectProtocol] = []
    private var followPending = false
    /// A follow stopped at a folder whose listing is running; it resumes when the listing arrives.
    private var followWaiting = false
    /// Folders are listed here, never in outline callbacks: a folder of 100,000 files took seconds.
    private let listingQueue = DispatchQueue(label: "porpoise.folders.listing", qos: .userInitiated, attributes: .concurrent)

    private static let cellID = NSUserInterfaceItemIdentifier("folder")
    /// Settings this panel depends on (nil: all settings were reset).
    private static let settingKeys: Set<String?> = ["foldersHome", "foldersHidden", nil]
    /// Entries looked at when guessing whether a folder has subfolders (it decides the disclosure triangle).
    private static let expandabilityScanLimit = 200
    /// A listing that takes longer than this shows "Loading…" on its folder.
    private static let loadingLabelDelay: TimeInterval = 0.15

    /// A folder in the tree; children are listed lazily (on a worker queue) and cached until the tree is rebuilt.
    final class Node {
        let url: URL
        private(set) var children: [Node]?
        private var expandable: Bool?
        /// Children from before `invalidate()`, reused so their expansion state survives a re-list.
        private var staleChildren: [Node]?
        /// The listing running for this node; a result from any other (older) listing is dropped.
        private var listing: Int?
        private static var listings = 0
        /// The missing child a re-list was made for: one re-list per missing folder, not one per follow.
        var relistedFor: String?
        init(_ url: URL) { self.url = url }

        var isLoading: Bool { listing != nil }

        var name: String {
            guard url.path == "/" else { return url.lastPathComponent }
            return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/"
        }

        /// Lists the children here and now (benchmarks and tests; the panel lists on its worker queue).
        func load(showHidden: Bool) -> [Node] {
            if let c = children { return c }
            return apply(Self.sortedSubfolderNames(of: url, showHidden: showHidden))
        }

        /// Marks a listing as started; pass the token back to `finishListing`.
        func beginListing() -> Int {
            Self.listings += 1
            listing = Self.listings
            return Self.listings
        }

        /// Takes the names a listing found, unless a newer listing or `invalidate()` replaced it.
        func finishListing(_ token: Int, _ names: [String]) -> Bool {
            guard listing == token else { return false }
            listing = nil
            _ = apply(names)
            return true
        }

        private func apply(_ names: [String]) -> [Node] {
            let old = Dictionary((staleChildren ?? []).map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            let c = names.map { old[$0] ?? Node(url.appendingPathComponent($0)) }
            children = c
            staleChildren = nil
            return c
        }

        /// Cheap check (first entries only, bounded before any full listing) unless the children are already known.
        func isExpandable(showHidden: Bool) -> Bool {
            if let c = children { return !c.isEmpty }
            if let e = expandable { return e }
            let e = !Self.subfolderNames(of: url, showHidden: showHidden, limit: FoldersPanel.expandabilityScanLimit, firstOnly: true).isEmpty
            expandable = e
            return e
        }

        /// Adds a hidden subfolder that the view is in (or under), so the tree can show the way there.
        func reveal(_ name: String) -> Node {
            var c = children ?? []
            if let n = c.first(where: { $0.url.lastPathComponent == name }) { return n }
            let n = Node(url.appendingPathComponent(name))
            c.append(n)
            c.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            children = c
            return n
        }

        /// Forgets the cached listing (the folder changed on disk); a listing still running is dropped.
        func invalidate() {
            staleChildren = children ?? staleChildren
            children = nil
            expandable = nil
            listing = nil
        }

        /// Subfolder names in the tree's order. Safe off the main thread: it only reads the file system.
        static func sortedSubfolderNames(of url: URL, showHidden: Bool) -> [String] {
            subfolderNames(of: url, showHidden: showHidden, limit: nil).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        /// Names of real subfolders (packages such as .app bundles are files here, as in the view). Hidden ones are
        /// dot folders and folders hidden in Finder (~/Library, /usr…), as in the view. `limit` caps the entries
        /// looked at, in directory order; only entries the directory reports as folders (or doesn't type) are
        /// stat'ed, so a folder of files costs one pass over its names.
        private static func subfolderNames(of url: URL, showHidden: Bool, limit: Int?, firstOnly: Bool = false) -> [String] {
            guard let dir = opendir(url.path) else { return [] }
            defer { closedir(dir) }
            var out: [String] = []
            var seen = 0
            while let e = readdir(dir) {
                if let limit, seen >= limit { break }
                let type = e.pointee.d_type
                let n = withUnsafeBytes(of: e.pointee.d_name) { raw in
                    FileManager.default.string(
                        withFileSystemRepresentation: raw.baseAddress!.assumingMemoryBound(to: CChar.self), length: Int(e.pointee.d_namlen))
                }
                if n == "." || n == ".." || (!showHidden && n.hasPrefix(".")) { continue }
                seen += 1
                guard type == DT_DIR || type == DT_UNKNOWN else { continue }
                let v = try? url.appendingPathComponent(n).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey])
                guard v?.isDirectory == true, v?.isPackage != true, showHidden || v?.isHidden != true else { continue }
                out.append(n)
                if firstOnly { break }
            }
            return out
        }
    }

    override init(frame: NSRect) {
        // The root `resetRoot()` sets below; nothing is listed before then.
        root = Node(Self.home)
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.target = self
        outline.action = #selector(clicked)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        // Connected last: changing the outline's style or columns reloads it, and a reload before it sits in its
        // scroll view lists the whole root and makes a cell for every row (in test instances that root was the
        // temporary folder: 20,000+ folders, over a minute of CPU at launch).
        outline.dataSource = self
        outline.delegate = self
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
            // Rebuilding collapses the tree, so only for the panel's own settings.
            if Self.settingKeys.contains(n.object as? String) { self?.resetRoot() }
            if n.object as? String == "appearancePreferences" || n.object as? String == "appearance" {
                // Refresh existing cells after the icon cache clears; keep the expanded tree intact.
                DispatchQueue.main.async { [weak self] in self?.outline.reloadData() }
            }
        }
        for name in [CloudAccounts.remoteChanged, CloudAccounts.changed] {
            ancestryObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self, self.remoteTree != nil, !self.followPending else { return }
                    self.followPending = true
                    DispatchQueue.main.async { [weak self] in
                        self?.followPending = false
                        self?.followCurrent()
                    }
                })
        }
        resetRoot()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    deinit {
        settingsObserver.map(NotificationCenter.default.removeObserver)
        ancestryObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private var showHidden: Bool { Settings.shared.foldersShowHidden }

    /// The home the tree starts from. Test instances use their own (a test home, or an empty folder of their own),
    /// never the user's: its protected folders raise privacy prompts that block open(). Not the temporary folder
    /// itself, which may hold tens of thousands of folders.
    private static var home: URL {
        let real = FileManager.default.homeDirectoryForCurrentUser
        guard Settings.isTesting else { return real }
        if Settings.shared.homeURL.standardizedFileURL != real.standardizedFileURL { return Settings.shared.homeURL }
        let own = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-test-home-\(getuid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }

    private static func isInHome(_ url: URL) -> Bool {
        let home = Self.home.path
        return url.path == home || url.path.hasPrefix(home + "/")
    }

    // MARK: Following the view

    private func resetRoot() {
        if let target = currentURL, RemoteFS.isRemote(target) {
            remoteTree?.showHidden = showHidden
            remoteTree?.reload()
            followCurrent()
            return
        }
        remoteTree = nil
        let inHome = currentURL.map(Self.isInHome) ?? true
        root = Node(Settings.shared.foldersLimitToHome && inHome ? Self.home : URL(fileURLWithPath: "/"))
        outline.reloadData()
        outline.expandItem(nil)
        followCurrent()
    }

    /// Expands down to the current folder and selects it.
    private func followCurrent() {
        guard let target = currentURL else { return }
        if RemoteFS.isRemote(target) {
            let chain = remoteChain(to: target)
            if let tree = remoteTree, let top = chain.first, RemoteFolderTree.sameLocation(tree.root.url, top) {
                tree.reveal(chain)
                if let selected = tree.selected { selectRemote(selected, in: tree) }
            } else {
                showRemote(chain)
            }
            return
        }
        if remoteTree != nil { resetRoot(); return }
        guard target.isFileURL else { return }
        let home = Self.home
        if Settings.shared.foldersLimitToHome && (root.url.path == home.path) != Self.isInHome(target) { resetRoot(); return }
        var chain: [URL] = []
        // The tree holds real folders: /tmp/x is shown as /private/tmp/x (symlinks are not folders here).
        var u = Self.realFolder(target)
        // Only inside the root: a symlink out of Home (~/code → /Volumes/x/code) resolves to a path that never
        // reaches it, and the chain would invent a node for a folder that isn't there.
        guard u.path.hasPrefix(root.url.path == "/" ? "/" : root.url.path + "/") || u.path == root.url.path else { return }
        while u.path.count >= root.url.path.count && u.path != root.url.path {
            chain.insert(u, at: 0)
            u = u.deletingLastPathComponent()
        }
        var parent: Node?
        followWaiting = false
        for c in chain {
            guard case .found(let n) = child(of: parent, at: c) else { break }
            if let p = parent { outline.expandItem(p) }
            parent = n
        }
        // A listing on the way runs this again; the selection stays as it is meanwhile.
        if followWaiting { return }
        guard let n = parent, case let row = outline.row(forItem: n), row >= 0 else {
            outline.deselectAll(nil)
            return
        }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func remoteChain(to url: URL) -> [URL] {
        let ancestors = PlacesModel.isCloud(url) ? CloudAccounts.shared.ancestors(of: url) : RemoteFS.pathAncestors(of: url)
        if ancestors.isEmpty {
            if let known = remoteTree?.path(to: url) { return known.map(\.url) }
            let accounts = CloudAccounts.shared
            if PlacesModel.isCloud(url), !url.path.isEmpty, url.path != "/", let account = accounts.account(for: url) {
                // The breadcrumb's account button opens this row too. An unknown parent chain stays unknown:
                // reveal never invents a child if the top row's listing does not contain it.
                let rows = account.provider.descriptor.roots.compactMap { accounts.url(account.id, root: $0.key) }
                if !rows.contains(where: { RemoteFolderTree.sameLocation($0, url) }),
                    let first = accounts.availableRows(account.id).first, let top = accounts.url(account.id, root: first)
                {
                    return [top, url]
                }
            }
        }
        return ancestors + [url]
    }

    /// Remote roots stay at the account row/namespace or server root, even when the selected branch is not loaded.
    private func showRemote(_ chain: [URL]) {
        guard let top = chain.first else { return }
        let tree = RemoteFolderTree(url: top)
        tree.showHidden = showHidden
        remoteTree = tree
        tree.onChange = { [weak self, weak tree] node in
            guard let self, let tree, self.remoteTree === tree else { return }
            // DirectoryModel can paint a cached page synchronously, including inside shouldExpandItem.
            // Let AppKit finish that disclosure operation before changing its rows.
            DispatchQueue.main.async { [weak self, weak tree, weak node] in
                guard let self, let tree, let node, self.remoteTree === tree, tree.find(node.url) === node else { return }
                self.outline.reloadItem(node, reloadChildren: true)
                self.restoreRemoteExpansion(tree.root)
                if let selected = tree.selected { self.selectRemote(selected, in: tree) }
            }
        }
        outline.reloadData()
        outline.expandItem(tree.root)
        tree.reveal(chain)
    }

    private func restoreRemoteExpansion(_ node: RemoteFolderTree.Node) {
        if node.isExpanded { outline.expandItem(node) }
        for child in node.children ?? [] { restoreRemoteExpansion(child) }
    }

    private func selectRemote(_ node: RemoteFolderTree.Node, in tree: RemoteFolderTree) {
        for ancestor in tree.path(to: node.url)?.dropLast() ?? [] { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    /// The folder with symlinks resolved (realpath keeps /private, unlike URL.resolvingSymlinksInPath).
    private static func realFolder(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        guard let r = realpath(std.path, nil) else { return std }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r))
    }

    private enum Lookup { case found(Node), listing, missing }

    /// The child folder at `url`; re-lists the parent once when it's missing (created since it was listed). While
    /// the parent's listing runs, the follow waits for it (`followWaiting`).
    private func child(of parent: Node?, at url: URL) -> Lookup {
        let p = parent ?? root
        guard let listed = p.children else {
            startListing(p)
            followWaiting = true
            return .listing
        }
        if let n = listed.first(where: { $0.url.path == url.path }) { return .found(n) }
        if p.relistedFor != url.path {
            p.relistedFor = url.path
            p.invalidate()
            startListing(p)
            followWaiting = true
            return .listing
        }
        // A hidden folder (/Volumes, /private, ~/.config…) on the way to the view's folder is shown anyway, as the
        // path there would otherwise be missing from the tree.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            outline.reloadItem(parent, reloadChildren: true)
            return .missing
        }
        let n = p.reveal(url.lastPathComponent)
        outline.reloadItem(parent, reloadChildren: true)
        return .found(n)
    }

    /// The children known so far; starts listing them when they aren't known yet.
    private func children(of node: Node) -> [Node] {
        if let c = node.children { return c }
        startListing(node)
        return []
    }

    /// Lists `node` on the worker queue and shows the result. A result for a tree that was rebuilt meanwhile (or
    /// for a listing `invalidate()` dropped) is thrown away.
    private func startListing(_ node: Node) {
        guard !node.isLoading else { return }
        let token = node.beginListing()
        let url = node.url, hidden = showHidden, tree = root
        listingQueue.async {
            let names = Node.sortedSubfolderNames(of: url, showHidden: hidden)
            DispatchQueue.main.async { [weak self, weak node] in
                guard let self, let node, self.root === tree, self.remoteTree == nil, node.finishListing(token, names) else { return }
                self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                if self.followWaiting { self.followCurrent() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadingLabelDelay) { [weak self, weak node] in
            guard let self, let node, node.isLoading, node !== self.root, self.outline.row(forItem: node) >= 0 else { return }
            self.outline.reloadItem(node)
        }
    }

    // MARK: Outline data

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if remoteTree != nil {
            return item == nil ? 1 : (item as? RemoteFolderTree.Node)?.children?.count ?? 0
        }
        return children(of: (item as? Node) ?? root).count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let tree = remoteTree {
            return item == nil ? tree.root! : (item as! RemoteFolderTree.Node).children![index]
        }
        return children(of: (item as? Node) ?? root)[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? RemoteFolderTree.Node { return node.isExpandable }
        return (item as? Node)?.isExpandable(showHidden: showHidden) ?? false
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let url = nodeURL(item) else { return nil }
        let v = (o.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView) ?? makeCell()
        v.imageView?.image = Icons.shared.image(IconTheme.folderIconName(url), size: 16)
        if let n = item as? RemoteFolderTree.Node {
            v.textField?.stringValue = n.name + (n.isLoading ? " — Loading…" : "")
            v.toolTip = n.message
            v.setAccessibilityLabel(n.name + (n.isLoading ? ", loading" : ""))
        } else {
            let n = item as? Node
            let loading = n?.isLoading == true
            v.textField?.stringValue = (n?.name ?? "") + (loading ? " — Loading…" : "")
            v.toolTip = nil
            v.setAccessibilityLabel(loading ? (n?.name ?? "") + ", loading" : nil)
        }
        return v
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        (item as? RemoteFolderTree.Node)?.expand()
        return true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? RemoteFolderTree.Node)?.collapse()
    }

    private func nodeURL(_ item: Any?) -> URL? { (item as? Node)?.url ?? (item as? RemoteFolderTree.Node)?.url }

    private func makeCell() -> NSTableCellView {
        let v = NSTableCellView()
        v.identifier = Self.cellID
        let img = NSImageView()
        img.frame = CGRect(x: 2, y: 4, width: 16, height: 16)
        let t = NSTextField(labelWithString: "")
        t.font = Theme.font
        t.textColor = Theme.windowText
        t.lineBreakMode = .byTruncatingTail
        t.frame = CGRect(x: 22, y: 3, width: 400, height: 17)
        t.autoresizingMask = [.width]
        v.addSubview(img)
        v.addSubview(t)
        v.imageView = img
        v.textField = t
        return v
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { BreezeRowView() }

    // MARK: Mouse

    @objc private func clicked() {
        guard let url = nodeURL(outline.item(atRow: outline.clickedRow)) else { return }
        onNavigate?(url, NSEvent.modifierFlags.contains(.command))
    }

    /// Return opens the folder selected with the keyboard (⌘Return: in a new tab).
    private func openSelected() {
        guard let url = nodeURL(outline.item(atRow: outline.selectedRow)) else { return }
        onNavigate?(url, NSEvent.modifierFlags.contains(.command))
    }

    /// Middle click opens in a new tab; other buttons (mouse back/forward) go up the responder chain.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        if let url = nodeURL(outline.item(atRow: row)) { onNavigate?(url, true) }
    }
}

// MARK: - Context menu

extension FoldersPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let url = nodeURL(outline.item(atRow: outline.clickedRow)) {
            let open = menu.addItem(withTitle: "Open in New Tab", action: #selector(openInTab(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = url; open.image = Icons.shared.menuIcon("tab-new")
            let props = menu.addItem(withTitle: "Get Info", action: #selector(props(_:)), keyEquivalent: "")
            props.target = self; props.representedObject = url; props.image = Icons.shared.menuIcon("document-properties")
            menu.addItem(.separator())
        }
        let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHidden), keyEquivalent: "")
        hidden.target = self; hidden.state = Settings.shared.foldersShowHidden ? .on : .off
        let home = menu.addItem(withTitle: "Limit to Home Folder", action: #selector(toggleHome), keyEquivalent: "")
        home.target = self; home.state = Settings.shared.foldersLimitToHome ? .on : .off
    }

    @objc private func openInTab(_ s: NSMenuItem) { if let u = s.representedObject as? URL { onNavigate?(u, true) } }
    @objc private func props(_ s: NSMenuItem) { if let u = s.representedObject as? URL { PropertiesWindow.show(urls: [u]) } }
    @objc private func toggleHidden() { Settings.shared.foldersShowHidden.toggle() }
    @objc private func toggleHome() { Settings.shared.foldersLimitToHome.toggle() }
}

/// The tree; Return opens the selected folder (arrows only move the selection, like Dolphin's panel).
private final class FolderOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// Table row highlight drawn like Dolphin's Places/Folders panels.
final class BreezeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.placesSelectedFill.setFill()
        bounds.fill()
    }
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
