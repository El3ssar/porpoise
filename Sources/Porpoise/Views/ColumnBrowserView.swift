import AppKit
import PorpoiseCore
import PorpoiseServices

/// Where ← and → go in Column view.
protocol ColumnNavigating: AnyObject {
    func columnKey(right: Bool, from list: ItemListView)
}

/// A Column view column that isn't the focused one: a folder on the path before it, or the folder its one selected
/// item opens. It lists its folder with its own model (any location: this Mac, a server, a cloud account).
final class BrowserColumn {
    let model: DirectoryModel
    let list: ItemListView
    let scroll = NSScrollView()
    /// The item of this column that the next column opens (the path through the columns).
    private(set) var pathItem: URL?
    weak var browser: ColumnBrowserView?
    /// The browser is changing this column's selection itself, not the user.
    private var settingPath = false

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
        model.onChange = { [weak self] in self?.list.relayout() }
        model.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.list.needsDisplay = true
            self.list.accessibilitySelectionChanged()
            if !self.settingPath { self.browser?.columnSelectionChanged(self) }
        }
        model.onPropsChanged = { [weak self] in self?.list.relayout() }
        model.onLoaded = { [weak self] in
            guard let self else { return }
            // The path item may have arrived with this listing.
            if let p = self.pathItem { self.showPath(p) }
        }
        if listing.map(model.takeListing) != true { model.reload() }
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
        if let shown, let i = model.index(of: shown) {
            if list.frames.count != model.rows.count { list.computeLayout() }
            list.scrollToItem(i)
        }
        list.needsDisplay = true
    }

    func close() {
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
    /// Widths the user gave columns, by folder, while this view lasts; the others open at the saved width.
    private var widths: [URL: CGFloat] = [:]
    private var previewWidth: CGFloat?
    /// Columns that went out of view, kept a moment to come back without being read again (Back, ←, a click on the
    /// path), and while the mouse that made them go is still down (a drag from one, its context menu).
    private var spare: [BrowserColumn] = []
    private static let spareLimit = 4
    /// The pane is going to another folder: its selection changes on the way, which says nothing about the columns.
    private var navigating = false
    private let scroller = Animator()
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
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        focusPoll?.invalidate()
        scroller.stop()
    }

    override var isFlipped: Bool { true }

    static func configure(_ scroll: NSScrollView, showing list: ItemListView) {
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.viewBackground
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
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
        return widths[Self.key(url)] ?? ViewStyleStore().browserColumnWidth
    }

    static let previewMinimum: CGFloat = 280

    static func key(_ u: URL) -> URL { u.isFileURL ? u.standardizedFileURL : u }

    /// The pane is about to go to `url`: the column already listing it lends its rows to the pane's model, and the
    /// folder the pane leaves stays at hand for the column it may become.
    func willNavigate(to url: URL) -> BrowserColumn? {
        navigating = true
        let leaving = container.url
        let lender = column(listing: url)
        // The folder left shows again as a column when the new one is below it (→, a click on its folder) or is its
        // parent (←, Up).
        let below = ColumnPath.chain(from: root, to: url)?.contains { Self.key($0) == Self.key(leaving) } ?? false
        let parent = Self.key(leaving.deletingLastPathComponent()) == Self.key(url)
        if below || parent, Self.key(leaving) != Self.key(url), column(listing: leaving) == nil, !container.model.items.isEmpty {
            keepSpare(BrowserColumn(url: leaving, listing: container.model, browser: self))
        }
        return lender
    }

    /// The pane went to its new folder: the columns follow.
    func didNavigate() {
        navigating = false
        if !ColumnPath.contains(root, container.url) { root = container.url }
        syncPath()
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
            setPreview(one)
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

    /// Settings the columns share with the focused one (the icon size, previews, the pane being active).
    func shareLook() {
        let p = container.model.props
        for c in before + [after].compactMap({ $0 }) {
            c.list.isActiveView = container.isActive
            var q = c.model.props
            q.setIconSize(p.iconSize(for: .columns), for: .columns)
            q.previews = p.previews
            if q != c.model.props { c.model.props = q }
        }
    }

    // MARK: Layout

    /// Puts the columns in place; `scrolling`: brings the last one into view.
    func arrange(scrolling: Bool) {
        shareLook()
        let shown = shownColumns
        // Under the handles, which stay on top.
        for (v, _) in shown where v.superview !== content { content.addSubview(v, positioned: .below, relativeTo: nil) }
        for (v, _) in shown { v.isHidden = false }
        preview.isHidden = !showsPreview || after != nil
        while handles.count < shown.count { handles.append(makeHandle()) }
        for (i, h) in handles.enumerated() { h.isHidden = i >= shown.count }
        layoutColumns()
        if scrolling { scrollToEnd() }
        content.needsDisplay = true
        container.columnsArranged()
    }

    override func layout() {
        super.layout()
        strip.frame = bounds
        layoutColumns()
    }

    /// The x of each column's right edge (a divider follows each).
    private(set) var dividers: [CGFloat] = []

    private func layoutColumns() {
        let h = max(0, strip.contentView.bounds.height)
        var x: CGFloat = 0
        dividers = []
        for (i, (v, url)) in shownColumns.enumerated() {
            let w = width(of: url)
            let isPreview = url == nil
            // The preview takes what's left of the window when that's more than its width.
            let fill = isPreview ? max(w, strip.contentView.bounds.width - x) : w
            v.frame = CGRect(x: x, y: 0, width: fill, height: h)
            x += fill
            dividers.append(x)
            if i < handles.count {
                handles[i].frame = CGRect(x: x - ColumnResizeHandle.width / 2, y: 0, width: ColumnResizeHandle.width, height: h)
                handles[i].isHidden = isPreview
            }
            x += 1
        }
        content.frame = CGRect(x: 0, y: 0, width: max(x, strip.contentView.bounds.width), height: h)
        for case let s as NSScrollView in shownColumns.map(\.view) {
            (s.documentView as? ItemListView)?.relayout()
        }
        content.needsDisplay = true
    }

    /// The last column in full view (or as much of it as fits, from its left edge), gliding there.
    func scrollToEnd() {
        guard let last = shownColumns.last?.view else { return }
        let clip = strip.contentView
        let visible = clip.bounds.width
        var target = clip.bounds.origin.x
        if last.frame.maxX > target + visible { target = last.frame.maxX - visible }
        // The focused column stays in view too.
        let focused = container.scroll.frame
        if focused.minX < target { target = focused.minX }
        if target > last.frame.minX { target = last.frame.minX }
        target = max(0, min(target, content.frame.width - visible))
        let from = clip.bounds.origin.x
        guard abs(target - from) > 0.5 else { return }
        scroller.run(
            duration: 0.22,
            step: { [weak self] p in
                guard let self else { return }
                self.strip.contentView.scroll(to: CGPoint(x: from + (target - from) * CGFloat(p), y: 0))
                self.strip.reflectScrolledClipView(self.strip.contentView)
            })
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
        h.onDragEnded = { [weak self] in self?.layoutColumns() }
        content.addSubview(h)
        return h
    }

    // MARK: Widths

    func resize(column i: Int, to w: CGFloat, all: Bool) {
        let shown = shownColumns
        guard i < shown.count else { return }
        let range = ViewStyleStore.browserColumnWidths
        let width = min(max(w, range.lowerBound), range.upperBound)
        if all {
            // Option: every column, and the width new ones open at (Finder).
            ViewStyleStore().browserColumnWidth = width
            widths = [:]
        } else if let url = shown[i].url {
            widths[Self.key(url)] = width
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
            widths[Self.key(url)] = fittingWidth(list)
        }
        layoutColumns()
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
        container.setURL(c.url)
        let model = container.model
        model.selection = selection.filter { model.index(of: $0) != nil }
        model.currentURL = current.flatMap { model.index(of: $0) != nil ? $0 : nil }
        model.anchorURL = anchor
        if let current, let i = model.index(of: current) { container.list.scrollToItem(i) }
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
    }
}

// MARK: - Keys

extension ColumnBrowserView: ColumnNavigating {
    /// ← goes to the column before (its folder selected); → into the selected folder, selecting its first item.
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
        container.delegate?.container(container, open: items, inNewTab: inNewTab)
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

/// The strip the columns sit on: draws the dividers between them.
final class ColumnStripContent: NSView {
    weak var browser: ColumnBrowserView?
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        Theme.viewBackground.setFill()
        dirty.fill()
        NSColor.separatorColor.setFill()
        for x in browser?.dividers ?? [] where x < bounds.width {
            CGRect(x: x, y: 0, width: 1, height: bounds.height).intersection(dirty).fill()
        }
    }
}
