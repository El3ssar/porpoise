import AppKit
import PorpoiseCore
import PorpoiseServices

/// Where ← and → go in Column view.
protocol ColumnNavigating: AnyObject {
    func columnKey(right: Bool, from list: ItemListView)
    /// A click in `list` (the focus goes to its column, if it's another one).
    func columnClicked(_ list: ItemListView)
}

/// A Column view column that isn't the focused one: a folder on the path before it, or the folder its one selected
/// item opens. It lists its folder with its own model (any location: this Mac, a server, a cloud account).
final class BrowserColumn {
    let model: DirectoryModel
    let list: ItemListView
    let scroll = NestedScrollView()
    /// The item of this column that the next column opens (the path through the columns).
    private(set) var pathItem: URL?
    weak var browser: ColumnBrowserView?
    /// The browser is changing this column's selection itself, not the user.
    private var settingPath = false
    /// What the column shows while it has no rows: a quiet line at its top (the focused column has the pane's own).
    let stateLabel = ColumnStateLabel()
    private var loadingWork: DispatchWorkItem?
    /// Where the column's rows go once it has listed and is laid out: where they were (the column was the focused
    /// one, or Back put them back). A column never scrolls on its own after a click elsewhere.
    var pendingOrigin: CGPoint?

    var url: URL { model.location }

    /// `listing`: a model already listing the same folder (the focused column's, when it becomes this one): its rows
    /// show at once while this model reads the folder again.
    init(url: URL, listing: DirectoryModel? = nil, browser: ColumnBrowserView) {
        self.browser = browser
        model = DirectoryModel(location: url, prefetchFolders: false)
        model.browsesColumns = true
        list = ItemListView(model: model)
        list.delegate = browser
        list.columnNavigator = browser
        ColumnBrowserView.configure(scroll, showing: list)
        scroll.setAccessibilityLabel(url.lastPathComponent)
        list.addSubview(stateLabel)
        model.onChange = { [weak self] in
            self?.list.relayout()
            self?.refreshState()
        }
        model.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.list.needsDisplay = true
            self.list.accessibilitySelectionChanged()
            if !self.settingPath { self.browser?.columnSelectionChanged(self) }
        }
        model.onPropsChanged = { [weak self] in
            guard let self else { return }
            self.list.relayout()
            // A pinch or ⌘-wheel over this column zoomed it: that's its own size now.
            if self.list.committingZoom { self.browser?.columnZoomed(self) }
        }
        model.onLoaded = { [weak self] in
            guard let self else { return }
            // The path item may have arrived with this listing.
            if let p = self.pathItem { self.showPath(p) }
            if let o = self.pendingOrigin {
                self.pendingOrigin = nil
                self.list.scroll(o)
            }
            self.refreshState()
        }
        if listing.map(model.takeListing) != true { model.reload() }
        refreshState()
    }

    /// Empty, still loading (after a moment: a quick listing never flashes it) or failed: said in a quiet line, in the
    /// pane's own words.
    func refreshState() {
        loadingWork?.cancel()
        loadingWork = nil
        guard model.rows.isEmpty else { return stateLabel.show(nil) }
        let loading = model.isLoading && model.items.isEmpty
        let state: ListState
        if let e = model.loadError, !loading {
            let missing = url.isFileURL && !FileManager.default.fileExists(atPath: url.path)
            state = LoadErrorPresentation.error(
                e, location: url, missing: missing, blockedByPrivacy: model.blockedByPrivacy, cloud: PlacesModel.isCloud(url))
        } else {
            state = LoadErrorPresentation.empty(
                loading: loading, searching: false, searchError: nil, filtering: model.filter.isActive, trash: false)
        }
        guard loading, stateLabel.isHidden else { return stateLabel.show(state) }
        let work = DispatchWorkItem { [weak self] in self?.stateLabel.show(state) }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ColumnStateLabel.loadingDelay, execute: work)
    }

    /// Selects `item` as the path to the next column (grey while the keys are elsewhere) and keeps it in view.
    func showPath(_ item: URL?) {
        pathItem = item
        settingPath = true
        defer { settingPath = false }
        let shown = item.flatMap { model.index(of: $0) }.map { model.rows[$0].item.url }
        model.selection = shown.map { [$0] } ?? []
        model.currentURL = shown
        model.anchorURL = shown
        if pendingOrigin == nil, let shown, let i = model.index(of: shown) {
            if list.frames.count != model.rows.count { list.computeLayout() }
            list.scrollToItem(i)
        }
        list.needsDisplay = true
    }

    func close() {
        loadingWork?.cancel()
        model.onChange = nil
        model.onSelectionChanged = nil
        model.onLoaded = nil
        model.onPropsChanged = nil
        list.delegate = nil
        list.columnNavigator = nil
        scroll.removeFromSuperview()
    }
}

/// Column view (Finder's): the folders from where the view started down to the focused one, side by side, then
/// the folder the focused column's one selected folder opens, or a preview of its one selected file.
///
/// The focused column is the pane's own list (`ViewContainer.list` and its model): every command, the selection,
/// the status bar, rename, drag and drop and VoiceOver act there, as in the other modes. The columns before and after
/// it are `BrowserColumn`s. Moving the focus to another column makes the pane go to that column's folder; its
/// listing shows at once (`DirectoryModel.showListing(of:)`) while it is read again.
final class ColumnBrowserView: NSView {
    unowned let container: ViewContainer
    /// The first column's folder: where the view was when it went into Column view (or was sent somewhere outside the
    /// columns since).
    private(set) var root: URL
    /// The columns before the focused one: `root` and the folders below it down to the focused folder's parent.
    private(set) var before: [BrowserColumn] = []
    /// The column the focused column's one selected folder opens.
    private(set) var after: BrowserColumn?
    let preview = ColumnPreviewView()
    /// The preview column shows (one file selected).
    private(set) var showsPreview = false
    let strip = NSScrollView()
    private let content = ColumnStripContent()
    private(set) var handles: [ColumnResizeHandle] = []
    /// Each column's own width and icon size, first to last, while it shows the same folder (and the ones closed for a
    /// moment on the way, until another folder opens in their place).
    private(set) var sizes: [ColumnSize] = []
    private(set) var previewWidth: CGFloat?
    /// The pane arrived in a folder: its column's own icon size goes to the pane, not the folder's saved one to it.
    private var arriving = false
    /// The folder the user opened (a double-click): it becomes the first column.
    var opening: URL?
    /// The columns as they were at the history entry Back or Forward goes to.
    var restoring: Snapshot?
    /// Columns that went out of view, kept a moment to come back without being read again (Back, ←, a click on the
    /// path), and while the mouse that made them go is still down (a drag from one, its context menu).
    private var spare: [BrowserColumn] = []
    private static let spareLimit = 4
    /// The pane is going to another folder: its selection changes on the way, which says nothing about the columns.
    private var navigating = false
    private let scroller = Animator(name: "columns.scroll")
    /// A click in another column moves the focus there once the mouse is up (a drag may start from it meanwhile).
    private var pendingFocus: BrowserColumn?
    private var focusPoll: Timer?
    private var previewWork: DispatchWorkItem?
    /// Whether a mouse button is down (tests set it: the real mouse may be in someone's hand).
    nonisolated(unsafe) static var mouseIsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    init(container: ViewContainer) {
        self.container = container
        root = container.url
        super.init(frame: .zero)
        strip.documentView = content
        strip.hasHorizontalScroller = true
        strip.hasVerticalScroller = false
        strip.autohidesScrollers = true
        strip.scrollerStyle = .overlay
        strip.drawsBackground = true
        strip.backgroundColor = Theme.viewBackground
        strip.borderType = .noBorder
        strip.verticalScrollElasticity = .none
        strip.horizontalScrollElasticity = .automatic
        addSubview(strip)
        content.browser = self
        setAccessibilityElement(true)
        setAccessibilityRole(.browser)
        setAccessibilityLabel("Columns")
        Theme.whenChanged(self) { [weak self] in self?.strip.backgroundColor = Theme.viewBackground }
        // Servers and cloud folders aren't watched as this Mac's are: the other columns follow an operation's changes
        // and the service's own (the focused column is the pane's, which already does).
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: .main) { [weak self] n in
                guard let self, let remote = n.userInfo?["remote"] as? Set<String>, !remote.isEmpty else { return }
                self.reloadOtherColumns { remote.contains(FileOperationsController.remoteKey($0)) }
            })
        observers.append(
            center.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) { [weak self] n in
                guard let self, let id = n.object as? String else { return }
                self.reloadOtherColumns { CloudAccounts.shared.backend?.accountID(for: $0) == id }
            })
    }

    private var observers: [NSObjectProtocol] = []

    /// Reads again the columns other than the focused one, on servers and in the cloud, whose folder `changed` names.
    func reloadOtherColumns(where changed: (URL) -> Bool) {
        for column in before + (after.map { [$0] } ?? []) where !column.url.isFileURL && changed(column.url) {
            column.model.reload()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // VoiceOver: a browser's columns, first to last (each a list titled by its folder, then the preview).
    override func accessibilityColumns() -> [Any]? { shownColumns.map(\.view) }
    override func accessibilityVisibleColumns() -> [Any]? {
        let shown = strip.contentView.bounds
        return shownColumns.map(\.view).filter { $0.frame.intersects(shown) }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        focusPoll?.invalidate()
        scroller.stop()
    }

    override var isFlipped: Bool { true }

    static func configure(_ scroll: NSScrollView, showing list: ItemListView) {
        // Overlay first, then tile: with "Show scroll bars: Always", setting the style after the scroller leaves the
        // content view a legacy scroller's width short until the next tile, and the column's rows stop short of it.
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.viewBackground
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.tile()
    }

    // MARK: Columns

    /// Every column shown, first to last, with the folder each lists (nil: the preview).
    var shownColumns: [(view: NSView, url: URL?)] {
        var out: [(NSView, URL?)] = before.map { ($0.scroll, $0.url) }
        out.append((container.scroll, container.url))
        if let after { out.append((after.scroll, after.url)) } else if showsPreview { out.append((preview, nil)) }
        return out
    }

    /// The folders of the columns, first to last (the preview has none).
    var folders: [URL] { shownColumns.compactMap(\.url) }

    func width(of url: URL?) -> CGFloat {
        guard let url else { return previewWidth ?? max(ViewStyleStore().browserColumnWidth, Self.previewMinimum) }
        return size(of: url)?.width ?? ViewStyleStore().browserColumnWidth
    }

    /// The icon size of the column listing `url`.
    func iconSize(of url: URL) -> CGFloat? { size(of: url)?.iconSize }

    /// Column `c` was zoomed under the pointer: its new icon size is its own.
    func columnZoomed(_ c: BrowserColumn) {
        let k = Self.key(c.url), s = c.model.props.iconSize(for: .columns)
        if let i = sizes.firstIndex(where: { Self.key($0.url) == k }), sizes[i].iconSize != s { sizes[i].iconSize = s }
    }

    private func size(of url: URL) -> ColumnSize? {
        let k = Self.key(url)
        return sizes.first { Self.key($0.url) == k }
    }

    static let previewMinimum: CGFloat = 280

    static func key(_ u: URL) -> URL { u.isFileURL ? u.standardizedFileURL : u }

    /// The pane is about to go to `url`: the column already listing it lends its rows to the pane's model, and the
    /// folder the pane leaves stays at hand for the column it may become.
    /// `leftAt`: where the focused column's rows were scrolled; the column it becomes keeps them there.
    func willNavigate(to url: URL, leftAt: CGPoint) -> BrowserColumn? {
        navigating = true
        let leaving = container.url
        let lender = column(listing: url)
        // The folder left shows again as a column when the new one is below it (→, a click on its folder) or is its
        // parent (←, Up).
        let below = ColumnPath.chain(from: root, to: url)?.contains { Self.key($0) == Self.key(leaving) } ?? false
        let parent = Self.key(leaving.deletingLastPathComponent()) == Self.key(url)
        if below || parent, Self.key(leaving) != Self.key(url), !container.model.items.isEmpty {
            if let c = column(listing: leaving) {
                c.pendingOrigin = leftAt
            } else {
                let c = BrowserColumn(url: leaving, listing: container.model, browser: self)
                c.pendingOrigin = leftAt
                keepSpare(c)
            }
        }
        return lender
    }

    /// The pane went to its new folder: the columns follow.
    func didNavigate() {
        navigating = false
        let here = Self.key(container.url)
        if let s = restoring, Self.key(s.focused) == here {
            root = s.root
            sizes = s.sizes
            previewWidth = s.previewWidth
        } else {
            restoring = nil
        }
        // An opened folder starts the columns, keeping its own size.
        if let o = opening, Self.key(o) == here { root = container.url }
        if !ColumnPath.contains(root, container.url) { root = container.url }
        arriving = true
        syncPath()
        arriving = false
        if let s = restoring {
            restoring = nil
            apply(s)
        }
    }

    /// A column (shown or kept) listing `url`.
    private func column(listing url: URL) -> BrowserColumn? {
        let k = Self.key(url)
        return (before + [after].compactMap { $0 } + spare).first { Self.key($0.url) == k }
    }

    private func keepSpare(_ c: BrowserColumn) {
        spare.removeAll { $0 === c }
        spare.insert(c, at: 0)
        c.scroll.isHidden = true
        while spare.count > Self.spareLimit { spare.removeLast().close() }
    }

    private func make(_ url: URL) -> BrowserColumn {
        if let i = spare.firstIndex(where: { Self.key($0.url) == Self.key(url) }) {
            let c = spare.remove(at: i)
            c.scroll.isHidden = false
            return c
        }
        if let c = (before + [after].compactMap { $0 }).first(where: { Self.key($0.url) == Self.key(url) }) { return c }
        return BrowserColumn(url: url, browser: self)
    }

    /// The columns before the focused one follow the pane's folder, then the one after it its selection.
    func syncPath() {
        let chain = ColumnPath.chain(from: root, to: container.url) ?? [container.url]
        let old = before
        before = chain.dropLast().map(make)
        for c in old where !before.contains(where: { $0 === c }) && c !== after { keepSpare(c) }
        for (i, c) in before.enumerated() { c.showPath(chain[i + 1]) }
        syncAfter(scrolling: true)
    }

    /// What the focused column's selection opens: a folder's column, a file's preview, or nothing (several items).
    func syncAfter(scrolling: Bool = true) {
        guard !navigating else { return }
        let model = container.model
        let one = model.selection.count == 1 ? model.selectedItems.first : nil
        let previous = after
        if let one, Self.opensColumn(one) {
            if previous.map({ Self.key($0.url) }) != Self.key(one.url) { after = make(one.url) }
            setPreview(nil)
        } else {
            after = nil
            setPreview(Settings.shared.columnsShowPreview ? one : nil)
        }
        if let previous, previous !== after, !before.contains(where: { $0 === previous }) { keepSpare(previous) }
        after?.showPath(nil)
        arrange(scrolling: scrolling)
    }

    /// A folder (or another location with items, such as a server or an archive) opens a column; a share that macOS
    /// has to mount first doesn't, until it's opened.
    static func opensColumn(_ item: FileItem) -> Bool { item.isBrowsableFolder && !NetworkMounts.needsMount(item.url) }

    private func setPreview(_ item: FileItem?) {
        previewWork?.cancel()
        guard let item else {
            showsPreview = false
            preview.clear()
            return
        }
        showsPreview = true
        // Arrow keys running down a list show each file without reading every one of them on the way.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showsPreview else { return }
            self.preview.show(item.url, container: self.container)
        }
        previewWork = work
        if preview.shownURL == nil { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work) }
    }

    /// Settings the columns share with the focused one (previews, hidden files, the pane being active), and each
    /// column's own icon size. A zoom of the focused column (the pane's) is that column's own.
    func shareLook() {
        let p = container.model.props
        if !navigating, !arriving, let i = sizes.firstIndex(where: { Self.key($0.url) == Self.key(container.url) }) {
            sizes[i].iconSize = p.iconSize(for: .columns)
        }
        for c in before + [after].compactMap({ $0 }) {
            c.list.isActiveView = container.isActive
            var q = c.model.props
            if let s = iconSize(of: c.url) { q.setIconSize(s, for: .columns) }
            q.previews = p.previews
            // Hidden files show in every column or in none (⌥⌘. acts on the focused one).
            q.showHidden = p.showHidden
            if q != c.model.props { c.model.props = q }
        }
    }

    // MARK: Layout

    /// Puts the columns in place; `scrolling`: brings the last one into view.
    func arrange(scrolling: Bool) {
        fitSizes()
        if arriving, let s = iconSize(of: container.url), container.model.props.iconSize(for: .columns) != s {
            var p = container.model.props
            p.setIconSize(s, for: .columns)
            container.model.props = p
        }
        shareLook()
        let shown = shownColumns
        // Under the handles, which stay on top.
        for (v, _) in shown where v.superview !== content { content.addSubview(v, positioned: .below, relativeTo: nil) }
        for (v, _) in shown { v.isHidden = false }
        // Out of the window when it doesn't show: a video or song playing in it stops.
        if !showsPreview || after != nil { preview.removeFromSuperview() }
        while handles.count < shown.count { handles.append(makeHandle()) }
        for (i, h) in handles.enumerated() { h.isHidden = i >= shown.count }
        layoutColumns()
        if scrolling { scrollToEnd() }
        content.needsDisplay = true
        container.columnsArranged()
    }

    override func layout() {
        super.layout()
        let resized = strip.frame.width != bounds.width
        strip.frame = bounds
        layoutColumns()
        // The pane got wider or narrower (the window, a panel): the columns keep their
        // widths and follow, the last one (and the focused one) in view, then settle on a column's edge.
        if resized, !scroller.isRunning { keepEndInView() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scrollToEnd()
    }

    /// The x of each column's right edge (a divider follows each).
    private(set) var dividers: [CGFloat] = []
    /// Where the strip rests: the last column (and the focused one) in view, no column cut on the left.
    private(set) var endOrigin: CGFloat = 0
    /// The same before it moves on to a column's edge: where it follows the pane while that changes width.
    private var followOrigin: CGFloat = 0
    private var settleWork: DispatchWorkItem?

    private func layoutColumns() {
        let h = max(0, strip.contentView.bounds.height)
        let visible = strip.contentView.bounds.width
        let shown = shownColumns
        // Each column at its width, the preview at its own for now.
        var frames: [CGRect] = []
        var x: CGFloat = 0
        for (_, url) in shown {
            let w = width(of: url)
            frames.append(CGRect(x: x, y: 0, width: w, height: h))
            x += w + 1
        }
        let focused = shown.firstIndex { $0.view === container.scroll }
        (followOrigin, endOrigin) = Self.endOrigins(of: frames, focused: focused, visible: visible)
        // The preview takes the rest of the strip where it rests.
        if let last = frames.indices.last, shown[last].url == nil {
            frames[last].size.width = max(frames[last].width, endOrigin + visible - frames[last].minX)
        }
        dividers = []
        for (i, (v, url)) in shown.enumerated() {
            v.frame = frames[i]
            dividers.append(frames[i].maxX)
            if i < handles.count {
                handles[i].frame = CGRect(
                    x: frames[i].maxX - ColumnResizeHandle.width / 2, y: 0, width: ColumnResizeHandle.width, height: h)
                handles[i].isHidden = url == nil
            }
        }
        content.frame = CGRect(x: 0, y: 0, width: max((frames.last?.maxX ?? 0) + 1, endOrigin + visible), height: h)
        for case let s as NSScrollView in shown.map(\.view) {
            (s.documentView as? ItemListView)?.relayout()
        }
        for c in before + [after].compactMap({ $0 }) where c.pendingOrigin != nil && !c.model.rows.isEmpty && h > 0 {
            c.list.scroll(c.pendingOrigin ?? .zero)
            c.pendingOrigin = nil
        }
        for c in before + [after].compactMap({ $0 }) where !c.stateLabel.isHidden { c.stateLabel.place() }
        content.needsDisplay = true
    }

    /// Where the strip shows the last column (as much of it as fits, from its left edge) and the focused one: as is
    /// (`follow`), and moved on to the next column's left edge, so that none shows cut in half on the left (`rest`).
    static func endOrigins(of frames: [CGRect], focused: Int?, visible: CGFloat) -> (follow: CGFloat, rest: CGFloat) {
        guard let last = frames.last, last.maxX > visible else { return (0, 0) }
        var t = last.maxX - visible
        if let focused, frames.indices.contains(focused) { t = min(t, frames[focused].minX) }
        t = max(0, min(t, last.minX))
        return (t, frames.first { $0.minX >= t - 0.5 }?.minX ?? t)
    }

    /// The strip is gliding to where it rests.
    var isScrolling: Bool { scroller.isRunning }

    /// The last column in full view (or as much of it as fits, from its left edge), gliding there.
    func scrollToEnd() {
        settleWork?.cancel()
        let from = strip.contentView.bounds.origin.x, target = endOrigin
        guard abs(target - from) > 0.5 else { return }
        scroller.run(
            duration: Motion.scroll,
            step: { [weak self] p in
                guard let self else { return }
                self.strip.contentView.scroll(to: CGPoint(x: from + (target - from) * CGFloat(p), y: 0))
                self.strip.reflectScrolledClipView(self.strip.contentView)
            })
    }

    /// The strip changed width under the columns: they follow at once, and glide to a column's edge once it stops.
    private func keepEndInView() {
        if abs(followOrigin - strip.contentView.bounds.origin.x) > 0.5 {
            strip.contentView.scroll(to: CGPoint(x: followOrigin, y: 0))
            strip.reflectScrolledClipView(strip.contentView)
        }
        settleWork?.cancel()
        guard abs(endOrigin - followOrigin) > 0.5 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.inLiveResize != true else { return }
            self.scrollToEnd()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func makeHandle() -> ColumnResizeHandle {
        let h = ColumnResizeHandle()
        let index = handles.count
        h.columnWidth = { [weak self] in
            guard let self, index < self.shownColumns.count else { return 0 }
            return self.width(of: self.shownColumns[index].url)
        }
        h.onResize = { [weak self] w, all in self?.resize(column: index, to: w, all: all) }
        h.onFit = { [weak self] all in self?.fit(column: index, all: all) }
        h.onFitEqually = { [weak self] in self?.fitEqually() }
        h.onDragEnded = { [weak self] in self?.layoutColumns() }
        content.addSubview(h)
        return h
    }

    // MARK: Sizes

    /// Each column shown keeps its size while its folder stays; a column opening another folder closes the ones after
    /// it, and the one it opens starts at the saved width with its parent's icon size.
    private func fitSizes() {
        let folders = self.folders
        guard let first = folders.first else { return }
        let keys = sizes.map { Self.key($0.url) }
        if let k = keys.firstIndex(of: Self.key(first)) {
            // The first column moved down (an opened folder): the ones before it go.
            sizes.removeFirst(k)
        } else if let top = sizes.first, let k = folders.firstIndex(where: { Self.key($0) == Self.key(top.url) }) {
            // Up from the first column: its parent comes before it.
            let width = ViewStyleStore().browserColumnWidth
            sizes.insert(contentsOf: folders[..<k].map { ColumnSize(url: $0, width: width, iconSize: top.iconSize) }, at: 0)
        }
        for (i, f) in folders.enumerated() {
            if i < sizes.count, Self.key(sizes[i].url) == Self.key(f) { continue }
            sizes.removeSubrange(min(i, sizes.count)...)
            let icon = i > 0 ? sizes[i - 1].iconSize : container.model.props.iconSize(for: .columns)
            sizes.append(ColumnSize(url: f, width: ViewStyleStore().browserColumnWidth, iconSize: icon))
        }
        // A file's preview replaced what was after its column.
        if showsPreview, sizes.count > folders.count { sizes.removeSubrange(folders.count...) }
    }

    func resize(column i: Int, to w: CGFloat, all: Bool) {
        let shown = shownColumns
        guard i < shown.count else { return }
        let range = ViewStyleStore.browserColumnWidths
        let width = min(max(w, range.lowerBound), range.upperBound)
        if all {
            // Option: every column, and the width new ones open at (Finder).
            ViewStyleStore().browserColumnWidth = width
            for j in sizes.indices { sizes[j].width = width }
        } else if let url = shown[i].url {
            setWidth(width, of: url)
        } else {
            previewWidth = max(width, Self.previewMinimum)
        }
        layoutColumns()
    }

    /// Double-click on a handle: the column as wide as its longest name (Option: every column so).
    func fit(column i: Int, all: Bool) {
        let shown = shownColumns
        guard i < shown.count else { return }
        let targets = all ? Array(shown.indices) : [i]
        for j in targets {
            guard let s = shown[j].view as? NSScrollView, let list = s.documentView as? ItemListView, let url = shown[j].url else { continue }
            setWidth(fittingWidth(list), of: url)
        }
        layoutColumns()
    }

    private func setWidth(_ w: CGFloat, of url: URL) {
        let k = Self.key(url)
        if let i = sizes.firstIndex(where: { Self.key($0.url) == k }) { sizes[i].width = w }
    }

    /// Every column as wide as the widest of them needs, and new ones open at that width (the handle's menu).
    func fitEqually() {
        let lists = shownColumns.compactMap { $0.url == nil ? nil : ($0.view as? NSScrollView)?.documentView as? ItemListView }
        guard let widest = lists.map(fittingWidth).max() else { return }
        resize(column: 0, to: widest, all: true)
    }

    /// Room for the longest name in `list`, its icon, tags and the chevron (the first 5,000 rows decide).
    func fittingWidth(_ list: ItemListView) -> CGFloat {
        var widest: CGFloat = 0
        for r in list.model.rows.prefix(5000) { widest = max(widest, list.textWidth(list.model.displayName(for: r.item))) }
        let chrome = 2 * ItemListView.columnsInset + 6 + list.iconSize + 6 + ItemListView.chevronWidth + 12
        let range = ViewStyleStore.browserColumnWidths
        return min(max(ceil(widest + chrome), range.lowerBound), range.upperBound)
    }

    // MARK: Focus

    /// The user changed a column's selection (a click): the focus goes to that column once the mouse is up.
    func columnSelectionChanged(_ c: BrowserColumn) {
        guard c.list.window != nil else { return }
        pendingFocus = c
        if !Self.mouseIsDown() { return focusPending() }
        guard focusPoll == nil else { return }
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Self.mouseIsDown() else { return }
                self.focusPending()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        focusPoll = t
    }

    private func focusPending() {
        focusPoll?.invalidate()
        focusPoll = nil
        guard let c = pendingFocus else { return }
        pendingFocus = nil
        focus(c)
    }

    /// The focus moves to column `c`: the pane goes to its folder, keeping what was selected there.
    func focus(_ c: BrowserColumn) {
        guard before.contains(where: { $0 === c }) || after === c else { return }
        let selection = c.model.selection, current = c.model.currentURL, anchor = c.model.anchorURL
        let origin = c.list.visibleRect.origin
        container.setURL(c.url)
        let model = container.model
        model.selection = selection.filter { model.index(of: $0) != nil }
        model.currentURL = current.flatMap { model.index(of: $0) != nil ? $0 : nil }
        model.anchorURL = anchor
        // Its rows stay where they were: a click never scrolls the column it's in.
        if container.list.frames.count != model.rows.count { container.list.computeLayout() }
        container.list.scroll(origin)
        window?.makeFirstResponder(container.list)
        container.list.needsDisplay = true
    }

    /// The column showing `list`, if it's one of this view's own.
    func column(of list: ItemListView) -> BrowserColumn? {
        (before + [after].compactMap { $0 }).first { $0.list === list }
    }

    /// The column `list` belongs to gets the focus at once (its menu or an item it opens act on the pane's selection).
    private func focusNow(_ list: ItemListView) {
        guard let c = column(of: list) else { return }
        pendingFocus = nil
        focusPoll?.invalidate()
        focusPoll = nil
        focus(c)
    }

    /// The pane leaves Column view: the columns go.
    func tearDown() {
        for c in before + [after].compactMap({ $0 }) + spare { c.close() }
        before = []
        after = nil
        spare = []
        focusPoll?.invalidate()
        focusPoll = nil
        previewWork?.cancel()
        settleWork?.cancel()
    }
}

// MARK: - Keys

extension ColumnBrowserView: ColumnNavigating {
    /// ← goes to the column before (its folder selected); → into the selected folder, selecting its first item.
    func columnClicked(_ list: ItemListView) {
        if let c = column(of: list) { columnSelectionChanged(c) }
    }

    func columnKey(right: Bool, from list: ItemListView) {
        if list !== container.list { focusNow(list) }
        let model = container.model
        if right {
            guard let c = model.currentURL ?? (model.selection.count == 1 ? model.selection.first : nil),
                let i = model.index(of: c), Self.opensColumn(model.rows[i].item)
            else { return NSSound.beep() }
            container.setURL(model.rows[i].item.url)
            if let first = container.model.rows.first {
                container.list.select(first.item.url)
            } else {
                container.selectsFirstOnLoad = true
            }
        } else {
            let here = container.url
            guard let chain = ColumnPath.chain(from: root, to: here), chain.count > 1 else { return NSSound.beep() }
            container.setURL(chain[chain.count - 2], selecting: here)
        }
    }
}

// MARK: - The other columns' lists

extension ColumnBrowserView: ItemListViewDelegate {
    func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) {
        focusNow(view)
        container.itemList(view, open: items, inNewTab: inNewTab)
    }

    func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? {
        focusNow(view)
        return container.delegate?.container(container, menuFor: item)
    }

    func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {
        container.delegate?.container(container, drop: urls, onto: folder, operation: operation)
    }

    func itemList(_ view: ItemListView, rename item: FileItem, to name: String) { container.delegate?.container(container, rename: item, to: name) }
    func itemListDidBecomeActive(_ view: ItemListView) { container.delegate?.containerDidBecomeActive(container) }
    func itemList(_ view: ItemListView, hovered item: FileItem?) { container.itemList(container.list, hovered: item) }
    func itemListBackgroundDoubleClicked(_ view: ItemListView) {}
    func itemList(_ view: ItemListView, middleClicked item: FileItem) { container.delegate?.container(container, middleClicked: item) }
    func itemListQuickLook(_ view: ItemListView) {
        focusNow(view)
        container.delegate?.containerQuickLook(container)
    }
}

/// A column's own width and icon size, for the folder it shows.
struct ColumnSize: Equatable {
    var url: URL
    var width: CGFloat
    var iconSize: CGFloat
}

/// The strip the columns sit on: draws the dividers between them.
final class ColumnStripContent: NSView {
    weak var browser: ColumnBrowserView?
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        Theme.viewBackground.setFill()
        dirty.fill()
        Theme.separator.setFill()
        for x in browser?.dividers ?? [] where x < bounds.width {
            CGRect(x: x, y: 0, width: 1, height: bounds.height).intersection(dirty).fill()
        }
    }
}

/// A column's quiet line while it has no rows ("Folder is empty", "Loading…", what went wrong), centred at its top,
/// lighter than the focused column's message so the eye stays there. Clicks go through to the column.
final class ColumnStateLabel: NSTextField {
    static let loadingDelay: TimeInterval = 0.4
    private(set) var state: ListState?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 3
        font = .systemFont(ofSize: Tokens.FontSize.callout)
        isHidden = true
        setAccessibilityElement(false)
        Theme.whenChanged(self) { [weak self] in
            guard let self, let state = self.state else { return }
            self.textColor = state.isError ? Theme.viewTextInactive : Theme.disabledText
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ state: ListState?) {
        self.state = state
        isHidden = state == nil
        guard let state else { return }
        stringValue = state.title
        textColor = state.isError ? Theme.viewTextInactive : Theme.disabledText
        setAccessibilityElement(true)
        setAccessibilityLabel(state.title)
        superview?.needsLayout = true
        place()
    }

    /// Centred under the top inset of the column it's in, as wide as the column allows.
    func place() {
        guard let column = superview else { return }
        let width = max(0, column.bounds.width - 24)
        let height = cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 200)).height ?? 16
        frame = CGRect(x: 12, y: ItemListView.columnsTop + 10, width: width, height: ceil(height))
    }
}
