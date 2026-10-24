import AppKit
import PorpoiseCore
import PorpoiseFileSystem
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
        /// The folder changed on disk while it was being listed: it's listed once more when that listing is done.
        var changedWhileListing = false
        /// Hidden children shown anyway because they are on the way to the view's folder (`reveal`): a re-list keeps
        /// those that are still there, with what's open below them.
        private(set) var revealed: Set<String> = []
        init(_ url: URL) { self.url = url }

        var isLoading: Bool { listing != nil }

        /// The children the outline shows: during a re-list, the ones from before it. The outline keeps the row count it
        /// was last given until the new listing reloads the node, so it must be answered from the same list meanwhile.
        var shownChildren: [Node]? { children ?? staleChildren }

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
            revealed.formIntersection(names)
            return c
        }

        /// Whether it has subfolders, if known yet: from its children, or from a probe (`probeExpandable`).
        var knownExpandable: Bool? { children.map { !$0.isEmpty } ?? expandable }
        /// A probe of its first entries is running.
        private(set) var probing = false

        func beginProbe() { probing = true }

        /// What a probe found; dropped if the folder was invalidated meanwhile (it's probed again).
        func finishProbe(_ e: Bool) {
            guard probing else { return }
            probing = false
            if children == nil { expandable = e }
        }

        /// Cheap check (first entries only, bounded before any full listing). Safe off the main thread.
        static func hasSubfolder(_ url: URL, showHidden: Bool) -> Bool {
            !subfolderNames(of: url, showHidden: showHidden, limit: FoldersPanel.expandabilityScanLimit, firstOnly: true).isEmpty
        }

        /// Adds a hidden subfolder that the view is in (or under), so the tree can show the way there.
        func reveal(_ name: String) -> Node {
            var c = children ?? []
            if let n = c.first(where: { $0.url.lastPathComponent == name }) { return n }
            let n = Node(url.appendingPathComponent(name))
            revealed.insert(name)
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
            probing = false
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
        // The column stays as wide as the panel, however deep the tree: AppKit's default widens it with every level
        // expanded, so deep names ran past the sidebar's edge without an ellipsis.
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        col.resizingMask = .autoresizingMask
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
        ancestryObservers.append(
            NotificationCenter.default.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: .main) { [weak self] n in
                guard let paths = n.userInfo?["paths"] as? Set<String> else { return }
                self?.foldersChanged(paths)
            })
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
        outline.sizeLastColumnToFit()
    }

    // MARK: Following the disk

    /// Watches the tree's top and every open folder: one made, renamed or deleted there (by another app, the Terminal
    /// panel, another pane) shows in the tree, and a deleted one stops being there to click.
    private lazy var watcher = FolderWatcher { [weak self] paths in
        DispatchQueue.main.async { self?.foldersChanged(paths) }
    }

    /// The folders the tree shows the contents of: its top and the expanded ones. While one is listed again, the
    /// children it shows meanwhile count: the watch must not drop (and restart without) what's open below it.
    private func openFolders() -> [Node] {
        var out: [Node] = [], pending = [root]
        while let n = pending.popLast() {
            out.append(n)
            pending += (n.shownChildren ?? []).filter { outline.isItemExpanded($0) }
        }
        return out
    }

    static let relistDelay: TimeInterval = 0.3

    /// Tests of the listing mechanics turn it off: a re-list the disk asks for would race theirs.
    var watchesDisk = true { didSet { watchOpenFolders() } }

    func watchOpenFolders() {
        guard remoteTree == nil, watchesDisk else { return watcher.watch([]) }
        watcher.watch(openFolders().map(\.url))
    }

    /// Lists again the open folders among `paths` (real or as given), keeping what's expanded under them.
    func foldersChanged(_ paths: Set<String>) {
        guard remoteTree == nil else { return }
        let changed = Set(paths.map(FilePath.canonical))
        for n in openFolders() where n.shownChildren != nil && (changed.contains(FilePath.canonical(n.url.path)) || paths.contains(n.url.path)) {
            relist(n)
        }
    }

    /// Lists `n` again; one listing under way finishes first (a folder that keeps changing, such as the temporary
    /// folder, would otherwise restart it at every change and never show anything), then it's listed once more.
    private func relist(_ n: Node) {
        if n.isLoading {
            n.changedWhileListing = true
            return
        }
        n.invalidate()
        startListing(n)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { watchOpenFolders() }

    deinit {
        watcher.stop()
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

    /// Compared by their real paths: a home reached through a symlink (one under /var → /private/var) holds the folders
    /// under its real path too.
    private static func isInHome(_ url: URL) -> Bool {
        let home = realFolder(Self.home).path, path = realFolder(url).path
        return path == home || path.hasPrefix(home + "/")
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
        watchOpenFolders()
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
        let realRoot = Self.realFolder(root.url).path
        guard u.path.hasPrefix(realRoot == "/" ? "/" : realRoot + "/") || u.path == realRoot else { return }
        // Home's folders are under Home's path as the tree has it (a home reached through a symlink: /var/x, real
        // /private/var/x, W-266).
        if realRoot != root.url.path { u = URL(fileURLWithPath: root.url.path + u.path.dropFirst(realRoot.count)) }
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

    /// The children known so far (while a re-list runs, those from before it); starts listing them when they aren't
    /// known yet.
    private func children(of node: Node) -> [Node] {
        if let c = node.children { return c }
        startListing(node)
        return node.shownChildren ?? []
    }

    /// Lists `node` on the worker queue and shows the result. A result for a tree that was rebuilt meanwhile (or
    /// for a listing `invalidate()` dropped) is thrown away.
    private func startListing(_ node: Node) {
        guard !node.isLoading else { return }
        let token = node.beginListing()
        let url = node.url, hidden = showHidden, tree = root, revealed = node.revealed
        listingQueue.async { [weak self, weak node] in
            var names = Node.sortedSubfolderNames(of: url, showHidden: hidden)
            let kept = revealed.subtracting(names).filter { name in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
            }
            if !kept.isEmpty { names = (names + kept).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
            DispatchQueue.main.async { [weak self, weak node] in
                guard let self, let node, self.root === tree, self.remoteTree == nil else { return }
                let row = self.outline.selectedRow
                let selected = row >= 0 ? self.outline.item(atRow: row) as? Node : nil
                guard node.finishListing(token, names) else { return }
                self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                if self.followWaiting {
                    self.followCurrent()
                } else if let selected, self.outline.selectedRow < 0 {
                    // Listed again (a change on disk) above the shown folder: the reload dropped its selection.
                    let row = self.outline.row(forItem: selected)
                    if row >= 0 { self.outline.selectRowIndexes([row], byExtendingSelection: false) }
                }
                // Changed meanwhile: listed once more, a moment later (a folder that never stops changing is read at
                // most a few times a second, and what follows the view's folder through it gets its turn first).
                if node.changedWhileListing {
                    node.changedWhileListing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.relistDelay) { [weak self, weak node] in
                        guard let self, let node, self.root === tree else { return }
                        self.relist(node)
                    }
                }
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
        guard let node = item as? Node else { return false }
        if let e = node.knownExpandable { return e }
        // Not known yet: probed on the listing queue (never here: a folder on a network share, or one whose first
        // entries need a stat each, would hold the window); it shows a triangle meanwhile, gone if none is found.
        probeExpandable(node)
        return true
    }

    private func probeExpandable(_ node: Node) {
        guard !node.probing else { return }
        node.beginProbe()
        let url = node.url, hidden = showHidden, tree = root
        listingQueue.async { [weak self, weak node] in
            let e = Node.hasSubfolder(url, showHidden: hidden)
            DispatchQueue.main.async {
                guard let self, let node, self.root === tree, self.remoteTree == nil, node.probing else { return }
                node.finishProbe(e)
                if !e, self.outline.row(forItem: node) >= 0 { self.outline.reloadItem(node) }
            }
        }
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let url = nodeURL(item) else { return nil }
        let v = (o.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView) ?? makeCell()
        v.imageView?.image = Icons.shared.image(IconTheme.folderIconName(url), size: 16)
        if let n = item as? RemoteFolderTree.Node {
            v.textField?.stringValue = n.name + (n.isLoading ? " — Loading…" : "")
            v.toolTip = n.message ?? n.name
            v.setAccessibilityLabel(n.name + (n.isLoading ? ", loading" : ""))
        } else {
            let n = item as? Node
            let loading = n?.isLoading == true
            v.textField?.stringValue = (n?.name ?? "") + (loading ? " — Loading…" : "")
            // The whole name: a narrow sidebar shows long ones shortened in the middle.
            v.toolTip = n?.name
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
        watchOpenFolders()
    }

    private func nodeURL(_ item: Any?) -> URL? { (item as? Node)?.url ?? (item as? RemoteFolderTree.Node)?.url }

    private func makeCell() -> NSTableCellView {
        // The name field ends at the cell's edge and follows its width: one wider than the cell was clipped there with
        // no ellipsis ("-Users-dan", W-266).
        let v = NSTableCellView(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        v.identifier = Self.cellID
        let img = NSImageView()
        img.frame = CGRect(x: 2, y: 4, width: 16, height: 16)
        let t = NSTextField(labelWithString: "")
        t.font = Theme.font
        t.textColor = Theme.windowText
        // Names that differ at the end (dated, numbered, -Users-…-project folders) stay apart (DESIGN-CONTRACT T5).
        t.lineBreakMode = .byTruncatingMiddle
        t.cell?.truncatesLastVisibleLine = true
        t.frame = CGRect(x: 22, y: 3, width: v.bounds.width - 24, height: 17)
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
        if let url = nodeURL(outline.item(atRow: outline.contextRow ?? outline.clickedRow)) {
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
    var contextRow: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        contextRow = row
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if SecondaryClick.matches(event) {
            defer { contextRow = nil }
            SecondaryClick.present(event, in: self)
            return
        }
        contextRow = nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !SecondaryClick.matches(event) else { return }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        defer { contextRow = nil }
        SecondaryClick.present(event, in: self)
    }

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
