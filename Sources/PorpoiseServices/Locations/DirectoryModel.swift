import Foundation
import PorpoiseCore
import UniformTypeIdentifiers

/// One visible row: an item plus its tree depth (Details view's expandable folders).
public struct Row {
    public let item: FileItem
    public let depth: Int
    public var isExpanded: Bool
    /// Index into `groups`, -1 when not grouping.
    public var group: Int
}

public struct ItemGroup {
    public let title: String
    let firstRow: Int
    var count: Int
}

/// The items one view shows: loading, live updates, sorting, filtering, grouping, expansion and selection.
/// Main-thread only (Dolphin's KFileItemModel + selection manager).
public final class DirectoryModel {
    public private(set) var location: URL
    public private(set) var items: [FileItem] = []      // top level, unsorted, including hidden
    public private(set) var rows: [Row] = [] { didSet { rowIndex = nil; rowIndexByPath = nil } }
    public private(set) var groups: [ItemGroup] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// macOS privacy protection blocked the listing (e.g. the Trash needs Full Disk Access).
    public private(set) var blockedByPrivacy = false
    public var props: ViewProperties {
        didSet {
            guard props != oldValue else { return }
            // Item counts include hidden items only while they are shown.
            if props.showHidden != oldValue.showHidden { recountFolders = true }
            rebuild()
            onPropsChanged?()
        }
    }
    public var filter = NameFilter() { didSet { if filter != oldValue { rebuild() } } }

    /// Search results replace the folder listing while set (Search bar).
    public var searchResults: [FileItem]? { didSet { rebuild() } }
    public var isSearching: Bool { searchResults != nil }

    public private(set) var expanded: Set<URL> = []
    private var children: [URL: [FileItem]] = [:]
    private(set) var folderCounts: [URL: Int] = [:]
    private var pendingCounts: Set<URL> = []
    /// Re-count every shown folder on the next rebuild (a reload: their contents may have changed meanwhile).
    private var recountFolders = false

    public var selection: Set<URL> = [] { didSet { if selection != oldValue { onSelectionChanged?() } } }
    public var currentURL: URL?
    public var anchorURL: URL?

    public var onChange: (() -> Void)?
    public var onSelectionChanged: (() -> Void)?
    public var onPropsChanged: (() -> Void)?
    public var onLoaded: (() -> Void)?

    /// Re-lists the folder (and expanded subfolders) when any of them changes; reloads don't flicker.
    private lazy var watcher = FolderWatcher { [weak self] _ in
        DispatchQueue.main.async { self?.reload() }
    }
    /// Bumped by every reload: results of an older (slower) load are dropped.
    private var loadToken = 0

    /// Temporary display changes, shown but not saved (see `ViewOverride`): Icons for media folders, Details for search.
    private var dynamicOverride = ViewOverride()
    private var searchOverride = ViewOverride()
    /// The media-folder check runs once per visit, after the first listing: a later reload (a file changed) must not
    /// undo a view mode the user picked in the meantime.
    private var dynamicViewPending = true

    public init(location: URL) {
        self.location = location
        self.props = Self.storedProps(for: location)
    }

    /// The display style saved for a location; virtual locations (Recent Files, Tags, Smart Folders) have their own.
    private static func storedProps(for url: URL) -> ViewProperties {
        if AppLibrary.isActive(for: url) { return AppLibrary.props() }
        guard url.scheme == "recent" || url.scheme == "tags" || url.scheme == "smart" else { return Settings.shared.viewProperties(for: url) }
        var p = ViewProperties()
        p.mode = .details
        p.foldersFirst = false
        let byName = url.path == "/locations" || url.scheme == "tags" || url.scheme == "smart"
        p.sortRole = byName ? .name : .accessTime
        p.sortOrder = byName ? .ascending : .descending
        p.setRoles([.path, .accessTime], for: .details)
        return p
    }

    /// Shows the saved display style again (the "remember per folder" choice, the common style or a dynamic-view
    /// setting changed, or Restore Defaults ran), keeping a running search's Details view.
    public func reloadProps() {
        dynamicOverride = ViewOverride()
        searchOverride = ViewOverride()
        dynamicViewPending = true
        props = Self.storedProps(for: location)
        if !isLoading { applyDynamicView() }
        if isSearching { showSearchView() }
    }

    /// Search results: Details with a Path column, for as long as the search runs.
    public func showSearchView() {
        var p = props
        searchOverride.apply(to: &p) { p in
            p.mode = .details
            if !p.roles(for: .details).contains(.path) { p.setRoles([.path, .modificationTime], for: .details) }
        }
        props = p
    }

    /// Search closed: back to the folder's own view (what the user changed meanwhile stays).
    public func endSearchView() {
        props = searchOverride.removed(from: props)
    }

    // MARK: Location

    public func setLocation(_ url: URL) {
        let changed = url.standardizedFileURL != location.standardizedFileURL
        location = url
        if changed {
            expanded = []
            children = [:]
            folderCounts = [:]
            selection = []
            currentURL = nil
            anchorURL = nil
            items = []
            searchResults = nil
            dynamicOverride = ViewOverride()
            searchOverride = ViewOverride()
            dynamicViewPending = true
            props = Self.storedProps(for: url)
            // Stop watching the old folder now: virtual and remote locations don't use FSEvents.
            updateWatcher()
        }
        reload()
    }

    private var recentQuery: RecentFilesQuery?
    private var tagQuery: MetadataListQuery?

    // MARK: Per-item metadata (read lazily for drawn items, cleared on reload)

    /// Finder tags of loaded items (cleared on reload or after tagging).
    private var tagCache: [URL: [FinderTags.Tag]] = [:]
    public func tags(for item: FileItem) -> [FinderTags.Tag] {
        guard item.url.isFileURL else { return [] }
        if let t = tagCache[item.url] { return t }
        let t = FinderTags.read(item.url)
        tagCache[item.url] = t
        return t
    }
    public func refreshTags() { tagCache = [:] }
    private func tagMap(_ list: [FileItem]) -> [URL: [String]] {
        var m: [URL: [String]] = [:]
        for it in list {
            let t = tags(for: it)
            if !t.isEmpty { m[it.url] = t.map(\.name) }
        }
        return m
    }

    /// Cloud badges (iCloud Drive, File Provider), cached like tags.
    private var cloudCache: [URL: (state: CloudState, isCloud: Bool)] = [:]
    public func cloud(for item: FileItem) -> (state: CloudState, isCloud: Bool) {
        if let c = cloudCache[item.url] { return c }
        let c = CloudState.of(item.url)
        cloudCache[item.url] = c
        return c
    }
    public func refreshCloud() { cloudCache = [:] }

    /// Name as shown: the full name, or without its extension when Settings › View › "Always show file extensions"
    /// is off (folders and names that are only an extension keep theirs).
    public func displayName(for item: FileItem) -> String {
        guard !Settings.shared.showAllExtensions, !item.isBrowsableFolder, !item.fileExtension.isEmpty else { return item.name }
        let base = (item.name as NSString).deletingPathExtension
        return base.isEmpty ? item.name : base
    }

    public var isVirtual: Bool { !location.isFileURL }

    // MARK: Loading

    public func reload(keepSelection: Bool = true) {
        loadToken += 1
        let token = loadToken
        let url = location
        tagCache = [:]
        cloudCache = [:]
        // Every branch starts clean: an error or a query of the previous location must not leak into this one.
        loadError = nil
        blockedByPrivacy = false
        tagQuery = nil
        recentQuery = nil
        if url.scheme == "tags" || url.scheme == "smart" {
            isLoading = true
            let tag = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let finish: ([FileItem]) -> Void = { [weak self] list in
                guard let self, token == self.loadToken else { return }
                self.items = list
                self.isLoading = false
                self.rebuild()
                self.onLoaded?()
            }
            if url.scheme == "smart" {
                tagQuery = MetadataListQuery.smartFolder(URL(fileURLWithPath: url.path), done: finish)
                if tagQuery == nil {
                    // Set before finishing, so onLoaded shows it.
                    loadError = "This Smart Folder's search could not be read."
                    finish([])
                }
            } else {
                tagQuery = MetadataListQuery.tagged(tag, done: finish)
            }
            return
        }
        if url.scheme == "network" {
            NetworkBrowser.shared.start()
            items = NetworkBrowser.shared.items
            isLoading = false
            rebuild()
            onLoaded?()
            return
        }
        if let provider = RemoteFS.provider(for: url) {
            isLoading = true
            let expandedNow = expanded
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var listed: [FileItem] = []
                var err: String?
                do { listed = try provider.list(url) } catch { err = error.localizedDescription }
                var kids: [URL: [FileItem]] = [:]
                for e in expandedNow { kids[e] = (try? provider.list(e)) ?? [] }
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken else { return }
                    self.items = listed
                    self.children = self.keepingExpanded(kids)
                    self.isLoading = false
                    self.loadError = err
                    let alive = Set(self.allLoadedURLs())
                    if keepSelection { self.selection = self.selection.intersection(alive) }
                    self.rebuild()
                    self.onLoaded?()
                }
            }
            return
        }
        if AppLibrary.isActive(for: url) {
            isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let apps = AppLibrary.listAll()
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken else { return }
                    self.items = apps
                    self.isLoading = false
                    if keepSelection { self.selection = self.selection.intersection(Set(apps.map(\.url))) }
                    self.rebuild()
                    self.updateWatcher()
                    self.onLoaded?()
                }
            }
            return
        }
        if url.scheme == "recent" {
            isLoading = true
            let finish: ([FileItem]) -> Void = { [weak self] list in
                guard let self, token == self.loadToken else { return }
                self.items = list
                self.isLoading = false
                self.rebuild()
                self.onLoaded?()
            }
            if url.path == "/locations" {
                finish(RecentLocations.shared.urls.compactMap { FileItem.load($0) })
            } else {
                recentQuery = RecentFilesQuery { list in finish(list) }
            }
            return
        }
        isLoading = true
        let expandedNow = expanded
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var listed: [FileItem] = []
            var err: String?
            var privacy = false
            do { listed = try DirectoryLister.list(url) } catch {
                let ns = error as NSError
                let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                if ns.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                    // EPERM on a readable folder means macOS privacy protection (TCC), not file permissions.
                    privacy = access(url.path, R_OK) == 0 || posix == Int(EPERM)
                    err = privacy
                        ? "macOS protects this folder. Give Porpoise Full Disk Access in System Settings to see its contents."
                        : "You don't have permission to view this folder."
                } else {
                    err = "Could not open “\(url.lastPathComponent)”."
                }
            }
            var kids: [URL: [FileItem]] = [:]
            for e in expandedNow { kids[e] = (try? DirectoryLister.list(e)) ?? [] }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.items = listed
                self.children = self.keepingExpanded(kids)
                self.isLoading = false
                self.applyDynamicView()
                self.recountFolders = true
                self.loadError = err
                self.blockedByPrivacy = privacy
                let alive = Set(self.allLoadedURLs())
                if keepSelection { self.selection = self.selection.intersection(alive) }
                if let c = self.currentURL, !alive.contains(c) { self.currentURL = nil }
                self.rebuild()
                self.updateWatcher()
                self.onLoaded?()
            }
        }
    }

    /// Everything listed, search results included (a reload during a search keeps their selection).
    private func allLoadedURLs() -> [URL] {
        items.map(\.url) + children.values.flatMap { $0.map(\.url) } + (searchResults ?? []).map(\.url)
    }

    /// A reload's children, plus those of folders expanded while it ran (their own load may have finished first).
    private func keepingExpanded(_ kids: [URL: [FileItem]]) -> [URL: [FileItem]] {
        var out = kids
        for e in expanded where out[e] == nil { if let c = children[e] { out[e] = c } }
        return out
    }

    private func updateWatcher() {
        if AppLibrary.isActive(for: location) { watcher.watch(AppLibrary.roots); return }
        watcher.watch(location.isFileURL ? [location] + Array(expanded) : [])
    }

    // MARK: Building rows

    private func visible(_ list: [FileItem]) -> [FileItem] {
        let match = filter.matcher() ?? { _ in true }
        let hideBackups = Settings.shared.hideBackupFiles && !props.showHidden
        return list.filter { (props.showHidden || !$0.isHidden) && !(hideBackups && $0.name.hasSuffix("~")) && match($0.name) }
    }

    public func rebuild() {
        let choice = Settings.shared.sortingChoice
        var out: [Row] = []
        var grps: [ItemGroup] = []
        let base = visible(searchResults ?? items)
        let groupRole = props.effectiveGroupRole
        // Finder tags are read (and cached) only when sorting or grouping by them.
        let tagNames = props.sortRole == .tags || groupRole == .tags ? tagMap(base) : [:]
        let sorted = ItemSorter.sort(base, props: props, choice: choice, folderSizes: folderCounts, tags: tagNames)

        func add(_ list: [FileItem], depth: Int, groupIndex: Int) {
            for it in list {
                let isExp = expanded.contains(it.url) && props.mode == .details
                out.append(Row(item: it, depth: depth, isExpanded: isExp, group: groupIndex))
                if isExp, let kids = children[it.url] {
                    let vk = visible(kids)
                    let ks = ItemSorter.sort(vk, props: props, choice: choice, folderSizes: folderCounts,
                                             tags: props.sortRole == .tags ? tagMap(vk) : [:])
                    add(ks, depth: depth + 1, groupIndex: groupIndex)
                }
            }
        }

        if let role = groupRole {
            let parts = ItemGrouper.groups(sorted, role: role, props: props, choice: choice, folderSizes: folderCounts, tags: tagNames)
            for (gi, g) in parts.enumerated() {
                let start = out.count
                add(g.items, depth: 0, groupIndex: gi)
                grps.append(ItemGroup(title: g.title, firstRow: start, count: out.count - start))
            }
        } else {
            add(sorted, depth: 0, groupIndex: -1)
        }
        rows = out
        groups = grps
        requestFolderCounts()
        onChange?()
    }

    // MARK: Folder sizes (Details "Size" column shows item counts, Dolphin's default)

    private func requestFolderCounts() {
        guard Settings.shared.folderSizeMode != .none, location.isFileURL else { return }
        let all = recountFolders
        recountFolders = false
        let need = rows.map(\.item).filter { $0.isBrowsableFolder && (all || folderCounts[$0.url] == nil) && !pendingCounts.contains($0.url) }
        guard !need.isEmpty else { return }
        let urls = need.map(\.url)
        pendingCounts.formUnion(urls)
        let hidden = props.showHidden
        let mode = Settings.shared.folderSizeMode
        let depth = Settings.shared.folderSizeDepth   // read here: Settings is main-thread only
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var res: [URL: Int] = [:]
            for u in urls {
                if mode == .contentSize {
                    res[u] = Int(Self.contentSize(u, maxDepth: depth))
                } else {
                    res[u] = DirectoryLister.childCount(u, includeHidden: hidden) ?? -1
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (k, v) in res { self.folderCounts[k] = v; self.pendingCounts.remove(k) }
                if self.props.sortRole == .size { self.rebuild() } else { self.onChange?() }
            }
        }
    }

    /// Size of a folder's contents, limited to `maxDepth` levels (Dolphin's "up to N levels deep").
    static func contentSize(_ url: URL, maxDepth: Int) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        for case let u as URL in e {
            if e.level > maxDepth { e.skipDescendants(); continue }
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Dolphin's "Use icons view mode for locations which mostly contain media files".
    /// Shown, never saved as the folder's or the common style (`dynamicOverride`); checked once per visit.
    private func applyDynamicView() {
        guard dynamicViewPending, location.isFileURL else { return }
        dynamicViewPending = false
        guard Settings.shared.dynamicView, !Settings.shared.rememberPerFolder, items.count >= 4 else { return }
        let media = items.filter { $0.utType.map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false }.count
        if Double(media) / Double(items.count) >= 0.5, props.mode != .icons || !props.previews {
            var p = props
            dynamicOverride.apply(to: &p) { p in
                p.mode = .icons
                p.previews = true
            }
            props = p
        }
    }

    public func resetFolderSizes() {
        folderCounts = [:]
        pendingCounts = []
        requestFolderCounts()
    }

    // MARK: Expansion (Details)

    public func toggleExpanded(_ url: URL) { setExpanded(url, !expanded.contains(url)) }

    /// Settings › Details › "Expandable folders" turned off: the tree goes away.
    public func collapseAll() {
        guard !expanded.isEmpty else { return }
        let top = Set(items.map(\.url))
        selection = selection.intersection(top)
        if let c = currentURL, !top.contains(c) { currentURL = nil }
        if let a = anchorURL, !top.contains(a) { anchorURL = nil }
        expanded = []
        children = [:]
        updateWatcher()
        rebuild()
    }

    public func setExpanded(_ url: URL, _ on: Bool) {
        if on {
            expanded.insert(url)
            if children[url] == nil { loadChildren(of: url) }
        } else {
            // Collapse descendants too, and forget their listings: they are no longer watched, so they would go stale.
            let prefix = url.path + "/"
            let inside = { (u: URL) in u.path.hasPrefix(prefix) }
            expanded = expanded.filter { $0 != url && !inside($0) }
            children = children.filter { $0.key != url && !inside($0.key) }
            selection = selection.filter { !inside($0) }
            if let c = currentURL, inside(c) { currentURL = url }
            if let a = anchorURL, inside(a) { anchorURL = url }
        }
        updateWatcher()
        rebuild()
    }

    /// Lists an expanded folder off the main thread (it may be huge or on a slow mount), then shows its rows.
    private func loadChildren(of url: URL) {
        let token = loadToken
        let provider = RemoteFS.provider(for: url)   // sftp://, ftp://, adb:// folders expand through their provider
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let kids = (try? provider.map { try $0.list(url) } ?? DirectoryLister.list(url)) ?? []
            DispatchQueue.main.async {
                // A reload since then lists expanded folders itself; a collapse makes this one moot.
                guard let self, token == self.loadToken, self.expanded.contains(url) else { return }
                self.children[url] = kids
                self.rebuild()
            }
        }
    }

    // MARK: Queries

    /// URL → row, built on first use after `rows` changes: views look rows up per hover, draw and key press.
    private var rowIndex: [URL: Int]?
    /// The same by standardized path (/tmp/x vs /private/tmp/x style mismatches), built only after a miss.
    private var rowIndexByPath: [String: Int]?

    public func index(of url: URL) -> Int? {
        if rowIndex == nil {
            rowIndex = Dictionary(rows.enumerated().map { ($1.item.url, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let i = rowIndex?[url] { return i }
        if rowIndexByPath == nil {
            rowIndexByPath = Dictionary(rows.enumerated().map { ($1.item.url.standardizedFileURL.path, $0) },
                                        uniquingKeysWith: { first, _ in first })
        }
        return rowIndexByPath?[url.standardizedFileURL.path]
    }

    public var selectedItems: [FileItem] { rows.map(\.item).filter { selection.contains($0.url) } }

    public var visibleCounts: (folders: Int, files: Int, bytes: Int64) {
        var f = 0, n = 0; var b: Int64 = 0
        for r in rows where r.depth == 0 {
            if r.item.isBrowsableFolder { f += 1 } else { n += 1; b += r.item.size }
        }
        return (f, n, b)
    }

    public var selectedCounts: (folders: Int, files: Int, bytes: Int64) {
        var f = 0, n = 0; var b: Int64 = 0
        for it in selectedItems {
            if it.isBrowsableFolder { f += 1 } else { n += 1; b += it.size }
        }
        return (f, n, b)
    }

    public func folderSizeText(_ item: FileItem) -> String {
        guard let c = folderCounts[item.url] else { return "" }
        if c < 0 { return "" }
        return Settings.shared.folderSizeMode == .contentSize ? FileFormat.size(Int64(c)) : FileFormat.itemCount(c)
    }

    /// Text for a role of an item, as shown in Details columns / under names.
    public func text(for role: ItemRole, of item: FileItem) -> String {
        let s = Settings.shared
        switch role {
        case .name: return item.name
        case .size:
            if item.isBrowsableFolder { return folderSizeText(item) }
            // Apps and other bundles are folders inside: no meaningful byte count here (Finder shows "--" too).
            return item.isDirectory ? "--" : FileFormat.size(item.size)
        case .modificationTime, .creationTime, .accessTime:
            let d = role == .modificationTime ? item.modificationDate : (role == .creationTime ? item.creationDate : item.accessDate)
            guard let d else { return "" }
            return s.dateStyle == .relative ? FileFormat.relativeDate(d) : FileFormat.longDate(d)
        case .type: return item.typeDescription
        case .path: return item.url.deletingLastPathComponent().path
        case .extension_: return item.fileExtension
        case .permissions:
            let sym = FileFormat.permissions(item.posixPermissions, isDirectory: item.isDirectory)
            let num = String(item.posixPermissions & 0o777, radix: 8)
            switch s.permissionStyle {
            case .symbolic: return sym
            case .numeric: return num
            case .combined: return "\(sym) (\(num))"
            }
        case .owner: return item.owner ?? ""
        case .group: return item.group ?? ""
        case .linkDestination: return item.linkDestination ?? ""
        case .tags:
            return tags(for: item).map(\.name).joined(separator: ", ")
        }
    }

    /// Saves the shown properties as the folder's (or the common) style, minus the temporary overrides.
    public func saveProps() {
        guard !isVirtual else { return }
        let p = dynamicOverride.stored(searchOverride.stored(props))
        Settings.shared.save(p, for: location)
    }
}
