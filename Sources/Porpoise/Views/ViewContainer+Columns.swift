import AppKit
import PorpoiseCore
import PorpoiseServices

/// Column view in the pane: the browser takes the list's place and puts the list (the focused column) among its
/// columns. See `ColumnBrowserView`.
extension ViewContainer {
    var showsColumns: Bool { model.props.mode == .columns && !showsApps }

    /// Lays out the column browser in `frame` (Column view), or puts the list back where it was (any other mode).
    func layoutColumns(in frame: CGRect) {
        guard showsColumns else {
            leaveColumns()
            return
        }
        let browser: ColumnBrowserView
        if let b = columnBrowser {
            browser = b
        } else {
            browser = ColumnBrowserView(container: self)
            columnBrowser = browser
            model.browsesColumns = true
            list.columnNavigator = browser
            scroll.hasHorizontalScroller = false
            addSubview(browser, positioned: .below, relativeTo: listState)
            browser.frame = frame
            browser.syncPath()
        }
        browser.isHidden = false
        if browser.frame != frame { browser.frame = frame }
        browser.layoutSubtreeIfNeeded()
        columnsArranged()
    }

    /// The browser put its columns in place: the empty-folder and error messages cover the focused column only.
    func columnsArranged() {
        guard columnBrowser != nil, scroll.superview != nil, scroll.superview !== self else { return }
        listState.frame = convert(scroll.frame, from: scroll.superview)
    }

    private func leaveColumns() {
        guard let browser = columnBrowser else { return }
        let hadFocus = window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: browser) ?? false } ?? false
        browser.tearDown()
        browser.removeFromSuperview()
        columnBrowser = nil
        model.browsesColumns = false
        list.columnNavigator = nil
        scroll.hasHorizontalScroller = true
        addSubview(scroll, positioned: .below, relativeTo: listState)
        if hadFocus { window?.makeFirstResponder(list) }
    }

    /// Before the pane goes to `url`: in Column view, a folder outside the columns starts them again, with its own
    /// view settings (Columns stays unless that folder is set to show otherwise). Returns the column already listing
    /// `url`, whose rows the pane can show at once.
    func columnsWillNavigate(to url: URL) -> BrowserColumn? {
        guard let browser = columnBrowser else { return nil }
        if !ColumnPath.contains(browser.root, url) { model.browsesColumns = false }
        return browser.willNavigate(to: url)
    }

    /// After the pane went to its new folder (`lender`: the column that lent it its rows).
    func columnsDidNavigate(lender: BrowserColumn?, selecting: URL?) {
        guard let browser = columnBrowser else { return }
        // Its listing was taken as it is (current: read and watched there), or shows while the folder is read again.
        if let lender, model.items.isEmpty { model.showListing(of: lender.model) }
        if model.props.mode == .columns { model.browsesColumns = true }
        // The item to select is in the rows already: selected now, so the next column shows without waiting.
        if let s = selecting, let i = model.index(of: s) {
            list.select(model.rows[i].item.url)
            pendingSelect = nil
        }
        browser.didNavigate()
        needsLayout = true
    }

    /// The columns at the history entry the pane leaves, for Back and Forward to put back.
    func keepColumns() {
        columnSnapshots[history.index] = columnBrowser?.snapshot()
    }

    /// A new history entry after `from`: the entries that were after it are gone, and the oldest may have gone too.
    func columnsVisited(from: Int) {
        let dropped = from + 1 - history.index
        columnSnapshots = Dictionary(
            uniqueKeysWithValues: columnSnapshots.compactMap { i, s in i <= from && i - dropped >= 0 ? (i - dropped, s) : nil })
    }

    /// Back or Forward (`go`) to an entry: its columns as they were.
    func restoreColumns(_ go: () -> Void) {
        columnBrowser?.restoring = columnSnapshots[history.index]
        go()
        columnBrowser?.restoring = nil
    }
}
