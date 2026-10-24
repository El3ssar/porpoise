import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import UniformTypeIdentifiers

/// One visible row: an item plus its tree depth (Details view's expandable folders).
public struct Row: Sendable {
    public let item: FileItem
    public let depth: Int
    public var isExpanded: Bool
    /// Index into `groups`, -1 when not grouping.
    public var group: Int
    public init(item: FileItem, depth: Int, isExpanded: Bool, group: Int = -1) {
        self.item = item; self.depth = depth; self.isExpanded = isExpanded; self.group = group
    }
}

public struct ItemGroup {
    public let title: String
    let firstRow: Int
    var count: Int
}

/// The items one view shows: loading, live updates, sorting, filtering, grouping, expansion and selection.
/// Main-thread only (Dolphin's KFileItemModel + selection manager).
public final class DirectoryModel {
    /// What lists the location, and the load in progress.
    private var source: LocationContentSource
    private var currentLoad: LocationLoad?
    private var childLoads: [URL: LocationLoad] = [:]
    private var folderPrefetch: LocationLoad?
    private var hoverPrefetch: LocationLoad?
    private var transferObserver: NSObjectProtocol?
    private var gitSettingsObserver: NSObjectProtocol?
    private var gitObservation: GitStatusObservation?
    private var gitLocation: URL?
    private var gitHasDelivered = false
    private var gitObservationGeneration: UInt64 = 0
    public static let gitStatusChanged = Notification.Name("PorpoiseGitStatusChanged")
    public private(set) var gitStatus: GitFolderStatus?

    private func observeGit() {
        let enabled = Settings.shared.showGitStatus && kind == .local
        let next = enabled ? location : nil
        guard next != gitLocation else { return }
        gitObservation?.cancel(); gitObservation = nil
        gitLocation = next; gitStatus = nil; gitHasDelivered = false
        gitObservationGeneration &+= 1
        guard let next else { return }
        let generation = gitObservationGeneration
        // Window construction lists its models synchronously; the app draws that window before this next main turn.
        // Re-evaluate generation so a navigation or a Settings change never discovers a stale repository.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gitObservationGeneration == generation else { return }
            self.gitObservation = GitStatusService.shared.observe(next) { [weak self] status in
                guard let self, self.gitObservationGeneration == generation else { return }
                self.gitStatus = status; self.gitHasDelivered = true
                NotificationCenter.default.post(name: Self.gitStatusChanged, object: self)
            }
        }
    }
    private var incomingItems: [FileItem] = []
    public private(set) var incomingProgress: [URL: Double] = [:]
    private func updateIncoming() {
        let activities = FileOperationsController.shared.activities.filter { $0.state.isActive }
        let pairs = activities.compactMap { activity -> (FileItem, Double)? in
            guard let item = activity.incomingItem, item.url.deletingLastPathComponent().standardized == location.standardized else { return nil }
            return (item, activity.incomingFraction)
        }
        let next = pairs.map { $0.0 }
        incomingProgress = Dictionary(pairs.map { ($0.0.url, $0.1) }, uniquingKeysWith: max)
        if incomingItems != next { incomingItems = next; rebuild() } else if !next.isEmpty { onChange?() }
    }
    deinit {
        rowPreparation?.cancel(); currentLoad?.cancel(); folderPrefetch?.cancel(); hoverPrefetch?.cancel();
        for load in childLoads.values { load.cancel() }
        if let transferObserver { NotificationCenter.default.removeObserver(transferObserver) }
        if let gitSettingsObserver { NotificationCenter.default.removeObserver(gitSettingsObserver) }
    }
    public private(set) var location: URL
    public private(set) var items: [FileItem] = []  // top level, unsorted, including hidden
    /// Changes whenever the visible rows are replaced, for constant-time view cache invalidation.
    public private(set) var rowsRevision: UInt64 = 0
    public private(set) var rows: [Row] = [] {
        didSet {
            rowsRevision &+= 1
            selectionSnapshotCache = nil
            rowIndex = nil; rowIndexByPath = nil; rowFileKeys = nil; missedLookups = []
        }
    }
    public private(set) var groups: [ItemGroup] = []
    private var loadingListing = false
    public var isLoading: Bool { loadingListing || rowPreparation != nil }
    public private(set) var loadError: String?
    /// macOS privacy protection blocked the listing (e.g. the Trash needs Full Disk Access).
    public private(set) var blockedByPrivacy = false
    /// The folder being shown was moved or deleted (it had loaded before): the view moves to the nearest one left.
    public private(set) var locationVanished = false
    /// The last location that loaded without an error.
    private var lastLoaded: URL?
    public var props: ViewProperties {
        didSet {
            guard props != oldValue else { return }
            // Item counts include hidden items only while they are shown.
            if props.showHidden != oldValue.showHidden { recountFolders = true }
            if Self.sortsAlike(props, oldValue), props.effectiveGroupRole == oldValue.effectiveGroupRole,
                props.mode == oldValue.mode || expanded.isEmpty
            {
                // Zoom, columns and a mode without expanded children change geometry, not rows or their order.
                onChange?()
            } else {
                rebuild(keepingOrder: Self.sortsAlike(props, oldValue))
            }
            onPropsChanged?()
        }
    }
    public var filter = NameFilter() { didSet { if filter != oldValue { rebuild(keepingOrder: true) } } }

    /// Search results replace the folder listing while set (Search bar).
    public var searchResults: [FileItem]? {
        didSet {
            searchSortGeneration += 1  // results still being sorted are out of date
            if applyingSortedResults { return }
            // A search's next batch adds to the last: only the new results are sorted, then merged in, so thousands
            // of results don't make each batch stall the window.
            if let new = searchResults, let old = oldValue, !old.isEmpty, new.count > old.count,
                old.indices.allSatisfy({ new[$0] == old[$0] })
            {
                rebuild(adding: Array(new[old.count...]))
            } else {
                rebuild()
            }
        }
    }
    public var isSearching: Bool { searchResults != nil }
    /// Bumped whenever the results change: a sort of older ones finishing later is dropped.
    private var searchSortGeneration = 0
    private var applyingSortedResults = false

    /// Sorts `items` off the main thread (thousands of results take a while), then hands over a closure that shows
    /// them, to call at once (between a snapshot and an animation). Results newer than these, or none (the search was
    /// closed), meanwhile: nothing happens.
    public func sortSearchResults(_ items: [FileItem], then show: @escaping (_ apply: () -> Void) -> Void) {
        let p = props, choice = Settings.shared.sortingChoice, sizes = folderCounts
        guard p.sortRole != .tags else { return show { self.searchResults = items } }  // tags are read here
        searchSortGeneration += 1
        let g = searchSortGeneration
        // Growing results (the same search's next batch): only what's new is sorted, then merged in.
        let old = searchResults ?? [], kept = sortedTop
        let grows = !old.isEmpty && kept != nil && items.count >= old.count && old.indices.allSatisfy { items[$0] == old[$0] }
        let shown = visible(grows ? Array(items[old.count...]) : items, filtered: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let top =
                grows
                ? ItemSorter.merge(kept ?? [], adding: shown, props: p, choice: choice, folderSizes: sizes)
                : ItemSorter.sort(shown, props: p, choice: choice, folderSizes: sizes)
            DispatchQueue.main.async {
                guard let self, g == self.searchSortGeneration else { return }
                show {
                    // Sorted with other settings meanwhile (the view's sort changed): sorted again here.
                    guard Self.sortsAlike(self.props, p), choice == Settings.shared.sortingChoice else { return self.searchResults = items }
                    self.applyingSortedResults = true
                    self.searchResults = items
                    self.applyingSortedResults = false
                    self.sortedTop = top
                    self.rebuild(keepingOrder: true)
                }
            }
        }
    }

    /// Whether two view settings put items in the same order (and show the same ones).
    private static func sortsAlike(_ a: ViewProperties, _ b: ViewProperties) -> Bool {
        a.sortRole == b.sortRole && a.sortOrder == b.sortOrder && a.foldersFirst == b.foldersFirst && a.hiddenLast == b.hiddenLast
            && a.showHidden == b.showHidden
    }

    /// What the shown results were searched for (set it before `searchResults`, which rebuilds).
    public var searchMatches: SearchMatches?

    /// The line of a content match to show with it.
    public func searchSnippet(for item: FileItem) -> String? {
        guard isSearching, let m = searchMatches, m.contents, !m.nameMatches(item) else { return nil }
        return m.snippets[item.url]
    }

    // MARK: Optimistic changes

    /// Changes made on a remote folder show at once and survive listings that arrive before the service answers, and
    /// confirmed ones also survive listings that were already under way: they go once a listing started after them ends.
    private var edits: [(id: UUID, edit: ListingEdit, originals: [FileItem], confirmedAt: Int?)] = []

    /// Shows a change now (rows appear, change or vanish, the selection stays); `endEdit` once the service answered.
    @discardableResult public func applyEdit(_ edit: ListingEdit) -> UUID {
        let id = UUID()
        let touched = edit.removed.union(edit.replaced.map(\.url))
        let originals = (items + children.values.flatMap { $0 }).filter { touched.contains($0.url) }
        edits.append((id, edit, originals, nil))
        show(edit)
        return id
    }

    /// The service answered: the change stays (until a newer listing has it), or `rollback` puts things back.
    public func endEdit(_ id: UUID, rollback: Bool = false) {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return }
        guard rollback else {
            if edits[i].confirmedAt == nil { edits[i].confirmedAt = loadToken }
            return
        }
        let (_, edit, originals, _) = edits.remove(at: i)
        let back = ListingEdit(
            folder: edit.folder, removed: Set(edit.added.map(\.url)),
            replaced: originals.filter { o in edit.replaced.contains { $0.url == o.url } },
            added: originals.filter { edit.removed.contains($0.url) })
        show(back)
    }

    /// The service's own version of a change (its real item for an optimistic row): shown, and kept until a newer
    /// listing has it.
    public func apply(_ edit: ListingEdit) {
        edits.append((UUID(), edit, [], loadToken))
        show(edit)
    }

    private func show(_ edit: ListingEdit) {
        items = edit.apply(to: items, in: location)
        for (folder, list) in children { children[folder] = edit.apply(to: list, in: folder) }
        selection.subtract(edit.removed)
        if let c = currentURL, edit.removed.contains(c) { currentURL = nil }
        rebuild()
    }

    /// A complete listing that started after a confirmed change has it: the change needn't be laid over listings anymore.
    private func listingArrived(_ token: Int) {
        edits.removeAll { $0.confirmedAt.map { $0 < token } ?? false }
    }

    private func withEdits(_ listed: [FileItem], in folder: URL) -> [FileItem] {
        edits.reduce(listed) { $1.edit.apply(to: $0, in: folder) }
    }

    public private(set) var expanded: Set<URL> = []
    private var children: [URL: [FileItem]] = [:]
    private(set) var folderCounts: [URL: Int] = [:]
    private var pendingCounts: Set<URL> = []
    /// Re-count every shown folder on the next rebuild (a reload: their contents may have changed meanwhile).
    private var recountFolders = false
    /// Counts from an earlier request (made with other settings) are dropped when they arrive late.
    /// Bumped when counts in flight no longer apply; their folder scans are cancelled with it.
    private var countGeneration = 0 {
        didSet {
            countCancellation.cancel()
            countCancellation = DiskCancellation()
        }
    }
    private var countCancellation = DiskCancellation()

    /// Constant-time invalidation for selection-dependent UI caches.
    public private(set) var selectionRevision: UInt64 = 0
    public var selection: Set<URL> = [] {
        didSet { if selection != oldValue { selectionRevision &+= 1; selectionSnapshotCache = nil; onSelectionChanged?() } }
    }
    public var currentURL: URL?
    public var anchorURL: URL?

    public var onChange: (() -> Void)?
    public var onSelectionChanged: (() -> Void)?
    public var onPropsChanged: (() -> Void)?
    public var onLoaded: (() -> Void)?
    /// A listing changed under a view that already showed it (Drive's answer after the saved listing painted, a change
    /// made in the browser or on another device): the view runs `apply` inside an animation, so rows appear, rename
    /// or vanish in place. Unset: applied at once.
    public var onRemoteUpdate: ((_ apply: () -> Void) -> Void)?
    /// A cloud folder shown from its saved listing while Drive is asked again (the status bar says "Updating…").
    public private(set) var isRefreshing = false

    /// Runs a change to a listing that was already shown through `onRemoteUpdate`.
    private func remoteUpdate(_ apply: () -> Void) {
        if let onRemoteUpdate { onRemoteUpdate(apply) } else { apply() }
    }

    /// Re-lists the folder (and expanded subfolders) when any of them changes; reloads don't flicker.
    private lazy var watcher = FolderWatcher { [weak self] _ in
        DispatchQueue.main.async { self?.folderChanged() }
    }
    /// The first change reloads at once; more within this time of that reload wait and make one reload at its end,
    /// so a download or a copy writing into the folder doesn't list it again several times a second.
    static let watchReloadInterval: TimeInterval = 0.5
    private var lastWatchReload: TimeInterval = -.infinity
    private var watchReloadPending = false

    private func folderChanged() {
        guard !watchReloadPending else { return }
        let wait = lastWatchReload + Self.watchReloadInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { return watchReload() }
        watchReloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.watchReloadPending = false
            self.watchReload()
        }
    }

    private func watchReload() {
        lastWatchReload = ProcessInfo.processInfo.systemUptime
        reload(changedOnly: true)
    }
    /// Bumped by every reload: results of an older (slower) load are dropped.
    private var loadToken = 0

    /// Temporary display changes, shown but not saved (see `ViewOverride`): Icons for media folders, Details for search.
    private var dynamicOverride = ViewOverride()
    private var searchOverride = ViewOverride()
    /// The media-folder check runs once per visit, after the first listing: a later reload (a file changed) must not
    /// undo a view mode the user picked in the meantime.
    private var dynamicViewPending = true

    private let prefetchFolders: Bool

    public init(location: URL, prefetchFolders: Bool = true) {
        self.prefetchFolders = prefetchFolders
        self.location = location
        self.source = LocationContentSources.source(for: location)
        self.props = ViewStyleStore().style(for: location)
        gitSettingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            guard note.object as? String == "showGitStatus" || note.object == nil else { return }
            guard let self else { return }
            self.observeGit()
            NotificationCenter.default.post(name: Self.gitStatusChanged, object: self)
        }
        transferObserver = NotificationCenter.default.addObserver(forName: FileOperationsController.activityChanged, object: nil, queue: .main) {
            [weak self] _ in self?.updateIncoming()
        }
    }

    /// Shows the saved display style again (the "remember per folder" choice, the common style or a dynamic-view
    /// setting changed, or Restore Defaults ran), keeping a running search's Details view.
    public func reloadProps() {
        dynamicOverride = ViewOverride()
        searchOverride = ViewOverride()
        dynamicViewPending = true
        columnOverride = ViewOverride()
        props = inColumns(ViewStyleStore().style(for: location))
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

    /// `lender`: a model whose current listing of `url` is taken instead of reading the folder (`takeListing`).
    public func setLocation(_ url: URL, takingListingOf lender: DirectoryModel? = nil) {
        let changed = url.standardizedFileURL != location.standardizedFileURL
        location = url
        observeGit()
        if changed {
            loadedNotificationPending = false
            incomingItems = []; incomingProgress = [:]
            expanded = []
            children = [:]
            folderCounts = [:]
            pendingCounts = []
            countGeneration += 1
            selection = []
            currentURL = nil
            anchorURL = nil
            items = []
            searchMatches = nil
            searchResults = nil
            dynamicOverride = ViewOverride()
            searchOverride = ViewOverride()
            dynamicViewPending = true
            columnOverride = ViewOverride()
            props = inColumns(ViewStyleStore().style(for: url))
            source = LocationContentSources.source(for: url)
            // Stop watching the old folder now: virtual and remote locations don't use FSEvents.
            updateWatcher()
            if let lender, takeListing(of: lender) { return }
        }
        reload()
    }

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
    public func refreshTags() {
        tagCache = [:]
        if props.sortRole == .tags || props.effectiveGroupRole == .tags { rebuild() }
    }
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
        if let c = accountCloud(item) { return c }
        if let c = cloudCache[item.url] { return c }
        let c = CloudState.of(item.url)
        cloudCache[item.url] = c
        return c
    }
    /// Items of connected accounts: their offline state, kept in memory by the offline service (no disk read).
    /// Folders aren't badged cloud-only (most would be); they show kept, downloading or a problem.
    private func accountCloud(_ item: FileItem) -> (state: CloudState, isCloud: Bool)? {
        guard !item.url.isFileURL, let service = CloudOfflineHub.service, service.supports(item.url) else { return nil }
        // Folders too: one not downloaded is in the cloud only, like its files.
        return (service.state(for: item.url), true)
    }

    /// Re-reads the cloud states in the background; the ones known stay shown meanwhile (no flicker).
    public func refreshCloud() { readMetadata(of: Set(cloudCache.keys), tags: false) }

    // Drawing reads only what's cached: on a network volume every read is a round trip, and a screenful of them
    // would stall scrolling. What's missing is read in the background, then `onMetadataLoaded` redraws.

    public var onMetadataLoaded: (() -> Void)?
    private var metadataWanted: Set<URL> = []
    private static let metadataQueue = DispatchQueue(label: "app.porpoise.item-metadata", qos: .userInitiated, autoreleaseFrequency: .workItem)

    /// Tags to draw: the cached ones, or none until they're read.
    public func shownTags(for item: FileItem) -> [FinderTags.Tag] {
        guard item.url.isFileURL else { return [] }
        if let t = tagCache[item.url] { return t }
        want(item.url)
        return []
    }

    /// Cloud state to draw: the cached one, or `.local` until it's read.
    public func shownCloud(for item: FileItem) -> (state: CloudState, isCloud: Bool) {
        if let c = accountCloud(item) { return c }
        if let c = cloudCache[item.url] { return c }
        if item.url.isFileURL { want(item.url) }
        return (.local, false)
    }

    /// Collects the misses of one drawing pass and reads them together once it's done.
    private func want(_ url: URL) {
        if metadataWanted.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let urls = self.metadataWanted
                self.metadataWanted = []
                self.readMetadata(of: urls, tags: true)
            }
        }
        metadataWanted.insert(url)
    }

    private func readMetadata(of urls: Set<URL>, tags: Bool) {
        guard !urls.isEmpty else { return }
        let token = loadToken
        Self.metadataQueue.async { [weak self] in
            let read = urls.map { ($0, tags ? FinderTags.read($0) : nil, CloudState.of($0)) }
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                for (url, t, c) in read {
                    if let t, self.tagCache[url] == nil { self.tagCache[url] = t }
                    self.cloudCache[url] = c
                }
                self.onMetadataLoaded?()
            }
        }
    }

    /// Name as shown: the full name, or without its extension when Settings › View › "Always show file extensions"
    /// is off (folders and names that are only an extension keep theirs).
    public func displayName(for item: FileItem) -> String {
        guard !Settings.shared.showAllExtensions, !item.isBrowsableFolder, !item.fileExtension.isEmpty else { return item.name }
        let base = (item.name as NSString).deletingPathExtension
        return base.isEmpty ? item.name : base
    }

    public var kind: LocationKind { LocationKind.of(location) }

    // MARK: Loading

    public func reload(keepSelection: Bool = true) { reload(keepSelection: keepSelection, changedOnly: false) }

    /// `changedOnly`: a change in the folder (FSEvents), not a new visit or the user's reload: item counts are taken
    /// again only for folders that changed.
    private func reload(keepSelection: Bool = true, changedOnly: Bool) {
        observeGit()
        if !changedOnly && gitHasDelivered { gitObservation?.retry() }
        loadedNotificationPending = false
        cancelRowPreparation()
        currentLoad?.cancel(); currentLoad = nil
        source = LocationContentSources.source(for: location)
        folderPrefetch?.cancel(); folderPrefetch = nil
        hoverPrefetch?.cancel(); hoverPrefetch = nil
        for load in childLoads.values { load.cancel() }
        childLoads = [:]
        loadToken += 1
        let token = loadToken
        let url = location
        tagCache = [:]
        cloudCache = [:]
        fileKeyCache = [:]
        metadataWanted = []
        // Every load starts clean: an error of the previous location must not leak into this one.
        loadError = nil
        blockedByPrivacy = false
        let source = self.source
        let cached = source.traits.paintsCache ? source.cached(url) : nil
        if let cached {
            let listed = withEdits(cached, in: url)
            // The same folder again (a change came in): what's different glides in; a new folder paints at once.
            let shown = !items.isEmpty && lastLoaded == url
            if shown, items != listed {
                remoteUpdate {
                    items = listed
                    if keepSelection { selection.formIntersection(Set(allLoadedURLs())) }
                    rebuild()
                }
            } else if !shown {
                items = listed
                rebuild()
            }
            loadingListing = false
            isRefreshing = true
            lastLoaded = url
            notifyLoaded()
        } else {
            loadingListing = true
            if source.traits.paintsCache { isRefreshing = false }
        }
        currentLoad = source.load(url, expanded: expanded) { [weak self] listing in
            guard let self, token == self.loadToken else { return }
            switch listing.part {
            case .whole: self.apply(listing, of: url, from: source, token: token, keepSelection: keepSelection, changedOnly: changedOnly)
            case .page: self.applyPage(listing.items, complete: listing.complete, hasCache: cached != nil, token: token, keepSelection: keepSelection)
            case .end: self.finish(listing, of: url, from: source, hadCache: cached != nil)
            }
        }
    }

    /// A paging source finished: the expanded folders are listed again and the visible ones read ahead. A failure
    /// after the saved listing painted stays quiet.
    private func finish(_ end: LocationListing, of url: URL, from source: LocationContentSource, hadCache: Bool) {
        loadingListing = false
        isRefreshing = false
        if let error = end.error {
            if !hadCache { loadError = error.message }
            notifyLoaded()
            return
        }
        lastLoaded = url
        for expandedURL in expanded { loadChildren(of: expandedURL) }
        notifyLoaded()
        let folders = rows.filter { $0.depth == 0 && $0.item.isBrowsableFolder }.map { $0.item.url }
        if prefetchFolders { folderPrefetch = source.prefetch(folders) }
    }

    /// A source's answer for the location (and the expanded folders it listed with it).
    private func apply(
        _ listing: LocationListing, of url: URL, from source: LocationContentSource, token: Int, keepSelection: Bool, changedOnly: Bool = false
    ) {
        let traits = source.traits
        if traits.optimisticEdits, listing.complete { listingArrived(token) }
        let before = changedOnly ? folderDates() : [:]
        items = traits.optimisticEdits ? withEdits(listing.items, in: url) : listing.items
        if let kids = listing.children { children = keepingExpanded(kids) }
        loadingListing = false
        if traits.dynamicView { applyDynamicView() }
        if traits.folderCounts { forgetFolderCounts(changedSince: changedOnly ? before : nil) }
        loadError = listing.error?.message
        blockedByPrivacy = listing.error == .privacy
        if let vanished = listing.vanished {
            locationVanished = vanished && lastLoaded?.standardizedFileURL == url.standardizedFileURL
        }
        // Only where a vanished folder can be told apart (a folder on this Mac) is the last folder that listed kept.
        if listing.error == nil, listing.vanished != nil { lastLoaded = url }
        if !preparesLocalRows,
            (traits.prunesSelection && keepSelection && !selection.isEmpty) || (traits.clearsCurrentItem && currentURL != nil)
        {
            let alive = Set(allLoadedURLs())
            if traits.prunesSelection, keepSelection { selection = selection.intersection(alive) }
            if traits.clearsCurrentItem, let c = currentURL, !alive.contains(c) { currentURL = nil }
        }
        rebuild()
        if traits.watch != .none { updateWatcher() }
        notifyLoaded()
    }

    private func applyPage(_ listed: [FileItem], complete: Bool, hasCache: Bool, token: Int, keepSelection: Bool) {
        guard token == loadToken, !hasCache || complete else { return }
        // A refresh never temporarily removes later pages or resets expanded rows.
        if complete { listingArrived(token) }
        let listed = withEdits(listed, in: location)
        guard items != listed else { return }
        let change = {
            self.items = listed
            if complete && keepSelection { self.selection.formIntersection(Set(self.allLoadedURLs())) }
            self.rebuild()
        }
        // Drive's answer to a folder painted from its saved listing: the differences glide in.
        if hasCache { remoteUpdate(change) } else { change() }
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
        switch source.traits.watch {
        case .fileSystem: watcher.watch([location] + Array(expanded))
        case .appLibrary: watcher.watch(AppLibrary.roots)
        case .none: watcher.watch([])
        }
    }

    // MARK: Building rows

    private func visible(_ list: [FileItem], filtered: Bool = true) -> [FileItem] {
        let match = filtered ? filter.matcher() : nil
        let hideBackups = Settings.shared.hideBackupFiles && !props.showHidden
        return list.filter {
            (props.showHidden || !$0.isHidden) && !(hideBackups && $0.name.hasSuffix("~")) && match?($0.name) != false
        }
    }

    /// The top level in order, before the name filter: typing in the filter bar narrows it without sorting again.
    private var sortedTop: [FileItem]?

    private var preparesLocalRows: Bool {
        props.sortRole == .tags || props.effectiveGroupRole == .tags
            || !isSearching && source is LocalSource && items.count + children.values.reduce(0, { $0 + $1.count }) >= 2000
    }
    private var rowPreparation: LocationLoad?
    private var rowPreparationGeneration: UInt64 = 0
    private var loadedNotificationPending = false
    // Internal dependency allows deterministic stale-delivery tests without sleeps or blocking a worker pool.
    var prepareRows = DirectoryModelPreparation.start

    private func cancelRowPreparation() {
        rowPreparationGeneration &+= 1
        rowPreparation?.cancel()
        rowPreparation = nil
    }

    private func notifyLoaded() {
        if isLoading { loadedNotificationPending = true } else { onLoaded?() }
    }

    private func prepareLocalRows(keepingOrder: Bool) {
        let generation = rowPreparationGeneration
        let snapshot = DirectoryModelPreparation(
            items: searchResults ?? items, incoming: isSearching ? [] : incomingItems, children: children, expanded: expanded, props: props,
            filter: filter,
            choice: Settings.shared.sortingChoice, hideBackups: Settings.shared.hideBackupFiles, sizes: folderCounts,
            knownTags: tagCache, ordered: keepingOrder ? sortedTop : nil,
            search: isSearching ? searchMatches : nil, retainedItems: isSearching ? items : [])
        // Never let a later filter/mode change reuse order from a superseded listing.
        if !keepingOrder { sortedTop = nil }
        rowPreparation = prepareRows(snapshot) { [weak self] result in
            guard let self, generation == self.rowPreparationGeneration else { return }
            self.rowPreparation = nil
            // Selection can change while the old rows remain visible during preparation.
            self.selection.formIntersection(result.alive)
            if let current = self.currentURL, !result.alive.contains(current) { self.currentURL = nil }
            self.sortedTop = result.top
            self.rows = result.rows
            self.groups = result.groups
            self.tagCache = result.tags
            self.rowFileKeys = result.keys
            self.fileKeyCache = result.keyCache
            self.requestFolderCounts()
            self.onChange?()
            if self.loadedNotificationPending {
                self.loadedNotificationPending = false
                self.notifyLoaded()
            }
        }
    }

    /// Rebuilds the rows; `keepingOrder` when only the name filter changed, `adding` when only those items were added
    /// to what's shown.
    public func rebuild(keepingOrder: Bool = false, adding: [FileItem]? = nil) {
        cancelRowPreparation()
        // Tag ordering needs IO even for a small listing. Search has its own incremental preparation.
        if preparesLocalRows {
            prepareLocalRows(keepingOrder: keepingOrder)
            return
        }
        let choice = Settings.shared.sortingChoice
        var out: [Row] = []
        var grps: [ItemGroup] = []
        let groupRole = props.effectiveGroupRole
        let top: [FileItem]
        if keepingOrder, let kept = sortedTop {
            top = kept
        } else if let adding, let kept = sortedTop, props.sortRole != .tags {
            top = ItemSorter.merge(kept, adding: visible(adding, filtered: false), props: props, choice: choice, folderSizes: folderCounts)
            sortedTop = top
        } else {
            let incomingURLs = Set(incomingItems.map(\.url))
            let listing = items.filter { !incomingURLs.contains($0.url) } + incomingItems
            let all = visible(searchResults ?? listing, filtered: false)
            // Finder tags are read (and cached) only when sorting by them.
            top = ItemSorter.sort(
                all, props: props, choice: choice, folderSizes: folderCounts,
                tags: props.sortRole == .tags ? tagMap(all) : [:])
            sortedTop = top
        }
        let sorted = filter.matcher().map { match in top.filter { match($0.name) } } ?? top
        let tagNames = groupRole == .tags ? tagMap(sorted) : [:]

        func add(_ list: [FileItem], depth: Int, groupIndex: Int) {
            for it in list {
                let isExp = expanded.contains(it.url) && props.mode == .details
                out.append(Row(item: it, depth: depth, isExpanded: isExp, group: groupIndex))
                if isExp, let kids = children[it.url] {
                    let vk = visible(kids)
                    let ks = ItemSorter.sort(
                        vk, props: props, choice: choice, folderSizes: folderCounts,
                        tags: props.sortRole == .tags ? tagMap(vk) : [:])
                    add(ks, depth: depth + 1, groupIndex: groupIndex)
                }
            }
        }

        if isSearching, let m = searchMatches, m.contents {
            // Names first, then what was found inside files; each keeps the sort order.
            var byName: [FileItem] = [], inside: [FileItem] = []
            for it in sorted {
                if m.nameMatches(it) { byName.append(it) } else { inside.append(it) }
            }
            for (title, list) in [("Name matches", byName), ("Content matches", inside)] where !list.isEmpty {
                let start = out.count
                add(list, depth: 0, groupIndex: grps.count)
                grps.append(ItemGroup(title: title, firstRow: start, count: out.count - start))
            }
        } else if let role = groupRole {
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
        if loadedNotificationPending {
            loadedNotificationPending = false
            notifyLoaded()
        }
    }

    // MARK: Folder sizes (Details "Size" column shows item counts, Dolphin's default)

    /// Modification dates of the listed folders (top level and expanded).
    private func folderDates() -> [URL: Date?] {
        var dates: [URL: Date?] = [:]
        for it in items + children.values.joined() where it.isBrowsableFolder { dates[it.url] = it.modificationDate }
        return dates
    }

    /// After a reload, counts are taken again. A folder's item count changes only with its modification date, so
    /// after a change in the folder (`before`: the dates listed before it) only the folders whose date changed, and
    /// new ones, are counted again. Content sizes depend on deeper folders too: all of them are.
    private func forgetFolderCounts(changedSince before: [URL: Date?]?) {
        guard let before, Settings.shared.folderSizeMode == .itemCount else { return recountFolders = true }
        for (url, date) in folderDates() where before[url] == nil || before[url]! != date {
            // A count under way may have read the folder before the change.
            if pendingCounts.contains(url) { return recountFolders = true }
            folderCounts[url] = nil
        }
    }

    /// Folder sizes are counted here, one model after another: a serial queue of its own always gets a thread,
    /// where utility work on the shared pool got none while other work kept every core busy.
    private static let countQueue = DispatchQueue(label: "app.porpoise.folder-counts", qos: .utility, autoreleaseFrequency: .workItem)

    private func requestFolderCounts() {
        guard Settings.shared.folderSizeMode != .none, source.traits.folderCounts else { return }
        let all = recountFolders
        recountFolders = false
        // Counting everything again supersedes the counts still under way: they were made with the old settings.
        // Their folders stop being pending too, or one no longer shown (in a collapsed folder) would never be counted.
        if all { countGeneration += 1; pendingCounts = []; FolderUsageCache.shared.invalidate(below: location) }
        let need = rows.map(\.item).filter { $0.isBrowsableFolder && (all || (folderCounts[$0.url] == nil && !pendingCounts.contains($0.url))) }
        guard !need.isEmpty else { return }
        let generation = countGeneration
        let urls = need.map(\.url)
        pendingCounts.formUnion(urls)
        let hidden = props.showHidden
        let mode = Settings.shared.folderSizeMode
        let depth = Settings.shared.folderSizeDepth  // read here: Settings is main-thread only
        let cancellation = countCancellation
        Self.countQueue.async { [weak self] in
            var res: [URL: Int] = [:]
            for u in urls where !cancellation.isCancelled {
                // A folder's size can mean walking a big tree: what Foundation autoreleases on the way goes after each.
                autoreleasepool {
                    if mode == .contentSize {
                        res[u] = Int(Self.contentSize(u, maxDepth: depth, cancellation: cancellation))
                    } else {
                        res[u] = DirectoryLister.childCount(u, includeHidden: hidden) ?? -1
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.countGeneration == generation else { return }
                for (k, v) in res { self.folderCounts[k] = v; self.pendingCounts.remove(k) }
                if self.props.sortRole == .size { self.rebuild() } else { self.onChange?() }
            }
        }
    }

    /// Size of a folder's contents, limited to `maxDepth` levels (Dolphin's "up to N levels deep").
    static func contentSize(_ url: URL, maxDepth: Int, cancellation: DiskCancellation = DiskCancellation()) -> Int64 {
        FolderUsageCache.shared.size(url, depth: maxDepth, cancellation: cancellation)
    }

    /// Dolphin's "Use icons view mode for locations which mostly contain media files".
    /// Shown, never saved as the folder's or the common style (`dynamicOverride`); checked once per visit.
    private func applyDynamicView() {
        guard dynamicViewPending, source.traits.dynamicView, !browsesColumns else { return }
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

    /// `url`, or the closest folder above it that still exists (where to go when it's gone).
    public static func nearestExisting(_ url: URL) -> URL {
        var u = url.standardizedFileURL
        var isDir: ObjCBool = false
        while u.path != "/", !(FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue) {
            u = u.deletingLastPathComponent()
        }
        return u
    }

    /// A folder counted and found empty (of what would show when expanded): Details shows no expander for it.
    public func isKnownEmpty(_ item: FileItem) -> Bool {
        Settings.shared.folderSizeMode == .itemCount && folderCounts[item.url] == 0
    }

    public func resetFolderSizes() {
        folderCounts = [:]
        pendingCounts = []
        countGeneration += 1
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
            for (child, load) in childLoads where child == url || inside(child) { load.cancel(); childLoads[child] = nil }
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
        // A cloud folder shows its saved listing until the service answers.
        if let cached = source.cached(url) { children[url] = cached }
        childLoads[url]?.cancel()
        childLoads[url] = source.load(url, expanded: []) { [weak self] listing in
            // A reload since then lists expanded folders itself; a collapse makes this one moot.
            guard let self, token == self.loadToken, self.expanded.contains(url) else { return }
            switch listing.part {
            case .page: return
            case .whole:
                self.children[url] = listing.items
                self.rebuild()
            case .end:
                guard listing.error == nil else { return }
                let edited = self.withEdits(listing.items, in: url)
                if self.children[url] != edited { self.children[url] = edited; self.rebuild() }
            }
            self.childLoads[url] = nil
        }
    }

    /// Hover is speculative and must never hold up a disclosure click.
    public func prefetch(_ item: FileItem?) {
        hoverPrefetch?.cancel()
        guard let item, item.isBrowsableFolder else { return }
        hoverPrefetch = LocationContentSources.source(for: item.url).prefetch([item.url])
    }

    // MARK: Queries

    /// URL → row, built on first use after `rows` changes: views look rows up per hover, draw and key press.
    private var rowIndex: [URL: Int]?
    /// URLs `index(of:)` didn't find in the current rows.
    private(set) var missedLookups: Set<URL> = []
    /// Canonical entry identity, built only after a URL miss. Remote scopes retain their complete URL.
    private var rowIndexByPath: [String: Int]?
    private var rowFileKeys: [String]?
    /// Keys already worked out since the last reload: each search batch or filter keystroke rebuilds the rows, and
    /// resolving all of them again took tens of milliseconds on the main thread for thousands of results.
    private var fileKeyCache: [URL: String] = [:]

    /// Stable for this delivered listing; rendering performs no filesystem work (all rows are keyed at once, on the
    /// first ask after the rows change).
    public func identity(ofRow index: Int) -> String {
        if let keys = rowFileKeys { return keys[index] }
        let missing = rows.map(\.item.url).filter { fileKeyCache[$0] == nil }
        for (url, key) in zip(missing, FilePath.keys(missing)) { fileKeyCache[url] = key }
        let keys = rows.map { fileKeyCache[$0.item.url]! }
        rowFileKeys = keys
        return keys[index]
    }

    public func index(of url: URL) -> Int? {
        if rowIndex == nil {
            rowIndex = Dictionary(rows.enumerated().map { ($1.item.url, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let i = rowIndex?[url] { return i }
        if rowIndexByPath == nil {
            rowIndexByPath = Dictionary(
                rows.indices.map { (identity(ofRow: $0), $0) },
                uniquingKeysWith: { first, _ in first })
        }
        // A URL not shown is asked about again and again (every view hears of every thumbnail made, and of its
        // folder): known misses cost nothing until the rows change.
        if missedLookups.contains(url) { return nil }
        if let index = rowIndexByPath?[FilePath.key(url)] { return index }
        // Drive permits redundant drive/resource context for the same opaque item. The provider owns that
        // equivalence; Dropbox's namespaces (and remote authorities) must never collapse by path alone. Another
        // service or account is never the same item: no need to go through the rows for it.
        guard !url.isFileURL, let cloud = source as? CloudSource, url.scheme == location.scheme, url.host == location.host,
            let i = rows.firstIndex(where: { cloud.provider.sameItem(url, $0.item.url) })
        else {
            if missedLookups.count > 4096 { missedLookups.removeAll() }
            missedLookups.insert(url)
            return nil
        }
        return i
    }

    /// In row order. Without copying every row's item first: the status bar asks on every selection change.
    public var selectedItems: [FileItem] { selectedSnapshot.items }

    public struct SelectionSnapshot {
        public let items: [FileItem]
        public let urls: [URL]
        public let cloudURLs: [URL]
        public let isLocal: Bool
        public let isManageable: Bool
    }
    private var selectionSnapshotCache: SelectionSnapshot?
    /// Menu validation asks about the same selection repeatedly. Every row or selection change drops this snapshot.
    public var selectedSnapshot: SelectionSnapshot {
        if let selectionSnapshotCache { return selectionSnapshotCache }
        let items = selectedRows.map { rows[$0].item }, urls = items.map(\.url)
        let snapshot = SelectionSnapshot(
            items: items, urls: urls, cloudURLs: urls.filter(PlacesModel.isCloud), isLocal: urls.allSatisfy(\.isFileURL),
            isManageable: urls.allSatisfy { $0.isFileURL || (RemoteFS.isRemote($0) && LocationKind.of($0) != .archive) })
        selectionSnapshotCache = snapshot
        return snapshot
    }

    /// The rows of the selected items, in order. A few are looked up (the status bar, the preview and Column view ask
    /// on every arrow key, and going through 100,000 rows each time made the keys lag); many are gone through.
    private var selectedRows: [Int] {
        guard !selection.isEmpty, let first = rows.first else { return [] }
        guard selection.count <= 256 else { return rows.indices.filter { selection.contains(rows[$0].item.url) } }
        if rowIndex == nil { _ = index(of: first.item.url) }
        return selection.compactMap { rowIndex?[$0] }.sorted()
    }

    public var visibleCounts: (folders: Int, files: Int, bytes: Int64) {
        var f = 0, n = 0; var b: Int64 = 0
        for r in rows where r.depth == 0 {
            if r.item.isBrowsableFolder { f += 1 } else { n += 1; b += r.item.size }
        }
        return (f, n, b)
    }

    public var selectedCounts: (folders: Int, files: Int, bytes: Int64) {
        var f = 0, n = 0; var b: Int64 = 0
        for i in selectedRows {
            let r = rows[i]
            if r.item.isBrowsableFolder { f += 1 } else { n += 1; b += r.item.size }
        }
        return (f, n, b)
    }

    public func folderSizeText(_ item: FileItem) -> String {
        guard let c = folderCounts[item.url] else { return "" }
        if c < 0 { return "" }
        return Settings.shared.folderSizeMode == .contentSize ? FileFormat.size(Int64(c)) : FileFormat.itemCount(c)
    }

    /// Text for a role of an item, as shown in Details columns / under names.
    /// A search result's folder as the Path column shows it: from the folder searched ("Demo/Photos"), or with the home
    /// folder as "~" when it is elsewhere, so the part that tells results apart isn't cut off.
    public static func searchPathText(parent: String, root: String, home: String = NSHomeDirectory()) -> String {
        // /tmp, /var and /etc are /private/…: results may be named one way and the folder the other. Strings only (this
        // runs for every row drawn), unlike standardizedFileURL, which asks the disk.
        func plain(_ p: String) -> String {
            for top in ["/tmp", "/var", "/etc"] where p == "/private" + top || p.hasPrefix("/private" + top + "/") {
                return String(p.dropFirst("/private".count))
            }
            return p
        }
        let parent = plain(parent)
        let root = plain(root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root)
        let name = (root as NSString).lastPathComponent
        if parent == root { return name }
        if root != "/", parent.hasPrefix(root + "/") { return name + "/" + parent.dropFirst(root.count + 1) }
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~/" + parent.dropFirst(home.count + 1) }
        return parent
    }

    public func text(for role: ItemRole, of item: FileItem) -> String {
        let s = Settings.shared
        switch role {
        case .name: return item.name
        case .size:
            if item.isBrowsableFolder { return folderSizeText(item) }
            // Apps and other bundles are folders inside: no meaningful byte count here (Finder shows "--" too).
            // Google Docs and the like take no storage: Drive has no size for them.
            if item.isWebDocument { return "—" }
            return item.isDirectory ? "--" : FileFormat.size(item.size)
        case .modificationTime, .creationTime, .accessTime, .sharedTime:
            guard let d = item.date(for: role) else { return "" }
            return s.dateStyle == .relative ? FileFormat.relativeDate(d) : FileFormat.longDate(d)
        case .type: return item.typeDescription
        case .path:
            // A Drive item's address names it by id, not by the folders it is in ("/folder", "/my-drive").
            if DriveLocation(url: item.url) != nil { return "Google Drive" }
            let parent = item.url.deletingLastPathComponent().path
            return isSearching ? Self.searchPathText(parent: parent, root: location.path) : parent
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
            return shownTags(for: item).map(\.name).joined(separator: ", ")
        }
    }

    /// Saves the shown properties as the folder's (or the common) style, minus the temporary overrides.
    /// Shows `p` here without saving it as the folder's own (a workspace's view settings); the dynamic view
    /// doesn't override it once the folder has loaded.
    /// Another mode leaves Column view (the pane may have started in it, with the folder's own settings).
    public func showProps(_ p: ViewProperties) {
        dynamicViewPending = false
        if p.mode != .columns { browsesColumns = false }
        props = inColumns(p)
    }

    public func saveProps() {
        let p = columnOverride.stored(dynamicOverride.stored(searchOverride.stored(props)))
        ViewStyleStore().save(p, for: location)
    }

    // MARK: Column view

    /// Column view: every folder shown in a column keeps the Columns mode while its own sort and other settings
    /// apply. The mode is shown, never saved as such a folder's own.
    public var browsesColumns = false {
        didSet { if browsesColumns != oldValue { applyColumnMode() } }
    }
    private var columnOverride = ViewOverride()
    /// In a split view, which Column view doesn't share: the mode a folder whose own (or the common) style is
    /// Columns shows in meanwhile. Never saved as its style.
    public var splitMode: ViewMode? {
        didSet { if splitMode != oldValue { applyColumnMode() } }
    }

    /// A folder's own settings as Column view shows them: never another mode, even for a moment (the pane would
    /// leave Column view); in a split, Columns gives way to `splitMode`.
    private func inColumns(_ own: ViewProperties) -> ViewProperties {
        var p = own
        if browsesColumns, p.mode != .columns {
            columnOverride.apply(to: &p) { $0.mode = .columns }
        } else if !browsesColumns, let s = splitMode, p.mode == .columns {
            columnOverride.apply(to: &p) { $0.mode = s }
        }
        return p
    }

    private func applyColumnMode() {
        let p = inColumns(columnOverride.isEmpty ? props : columnOverride.removed(from: props))
        if p != props { props = p }
    }

    /// Shows `other`'s listing of this same folder at once, while this model reads its own: in Column view a column
    /// becomes the focused one (or the other way round) without going blank. Its rows are taken as they are when both
    /// order and show items alike; otherwise its items are sorted here.
    public func showListing(of other: DirectoryModel) {
        guard other !== self, items.isEmpty, !other.items.isEmpty, !isSearching, !other.isSearching,
            Self.sameFolder(other.location, location)
        else { return }
        items = other.items
        folderCounts = other.folderCounts
        if Self.sortsAlike(props, other.props), props.effectiveGroupRole == other.props.effectiveGroupRole, filter == other.filter,
            other.expanded.isEmpty, other.rowPreparation == nil, incomingItems.isEmpty, other.incomingItems.isEmpty
        {
            // Built once where the rows live, then shared: each focus move would otherwise index them again.
            if other.rowIndex == nil, let first = other.rows.first { _ = other.index(of: first.item.url) }
            sortedTop = other.sortedTop
            rows = other.rows
            groups = other.groups
            // The same rows: their lookups too (rebuilding the path keys reads the disk for every row).
            rowIndex = other.rowIndex
            rowIndexByPath = other.rowIndexByPath
            rowFileKeys = other.rowFileKeys
            fileKeyCache = other.fileKeyCache
            tagCache = other.tagCache
            onChange?()
        } else {
            rebuild()
        }
    }

    /// Takes `other`'s listing of this folder as this model's own, without reading the folder again: `other` read it
    /// and has kept it current since (Column view moving the focus from one column to another). False when it can't
    /// (`other` is still reading or failed, or this model already lists something); then this model reads the folder.
    @discardableResult public func takeListing(of other: DirectoryModel) -> Bool {
        guard other !== self, items.isEmpty, !isSearching, !other.isSearching, !other.loadingListing, !other.isRefreshing,
            other.loadError == nil, other.edits.isEmpty, Self.sameFolder(other.location, location),
            other.lastLoaded.map({ Self.sameFolder($0, location) }) == true
        else { return false }
        cancelRowPreparation()
        currentLoad?.cancel(); currentLoad = nil
        loadToken += 1
        tagCache = [:]
        cloudCache = [:]
        fileKeyCache = [:]
        metadataWanted = []
        loadError = nil
        blockedByPrivacy = false
        locationVanished = false
        if other.items.isEmpty { rebuild() } else { showListing(of: other) }
        loadingListing = false
        lastLoaded = location
        observeGit()
        if Settings.shared.showGitStatus, let status = other.gitStatus {
            gitStatus = GitFolderStatus(
                root: status.root, folder: location, resolvedFolder: status.resolvedFolder,
                snapshot: status.snapshot, isPaused: status.isPaused, caseSensitive: status.caseSensitive)
            NotificationCenter.default.post(name: Self.gitStatusChanged, object: self)
        }
        updateWatcher()
        notifyLoaded()
        return true
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.isFileURL && b.isFileURL ? a.standardizedFileURL == b.standardizedFileURL : a == b
    }
}

/// An optimistic change to a folder's listing.
public struct ListingEdit: Equatable, Sendable {
    /// Where `added` items go.
    public var folder: URL
    public var removed: Set<URL>
    /// Same URL, new details (a rename).
    public var replaced: [FileItem]
    public var added: [FileItem]

    public init(folder: URL, removed: Set<URL> = [], replaced: [FileItem] = [], added: [FileItem] = []) {
        self.folder = folder
        self.removed = removed
        self.replaced = replaced
        self.added = added
    }

    /// `list` (the listing of `folder`) with the change.
    public func apply(to list: [FileItem], in listed: URL) -> [FileItem] {
        let byURL = Dictionary(replaced.map { ($0.url, $0) }, uniquingKeysWith: { $1 })
        var out = list.compactMap { removed.contains($0.url) ? nil : byURL[$0.url] ?? $0 }
        if listed == folder {
            let have = Set(out.map(\.url))
            out += added.filter { !have.contains($0.url) }
        }
        return out
    }
}
