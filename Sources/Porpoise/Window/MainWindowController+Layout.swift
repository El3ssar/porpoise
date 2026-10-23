import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Window layout

/// The window's view as data and back: named workspaces save it, session restoration keeps it.
extension MainWindowController {
    /// What this window shows: tabs, panes (location, view settings, filter, scroll position), panels and frame.
    /// Passwords never go in it.
    func captureLayout() -> WindowLayout {
        let tabLayouts = tabs.map { t in
            TabLayout(
                primary: paneLayout(t.primary), secondary: t.secondary.map(paneLayout), activeIsSecondary: t.activeIsSecondary,
                splitFraction: t.isSplit ? Double(t.splitShare) : nil, title: t.customTitle, linked: t.linkedRoots != nil)
        }
        let panels = PanelLayout(
            places: showPlaces, folders: showFolders, information: showInformation, terminal: showTerminal, shelf: showShelf,
            sidebarWidth: PanelSize.sidebarWidth.stored.map(Double.init), informationWidth: PanelSize.informationWidth.stored.map(Double.init),
            terminalHeight: PanelSize.terminalHeight.stored.map(Double.init))
        let frame = window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init) }
        return WindowLayout(tabs: tabLayouts, activeTab: current, panels: panels, frame: frame)
    }

    private func paneLayout(_ c: ViewContainer) -> PaneLayout {
        let url = RemoteFS.withoutPassword(c.url)
        let root = c.columnBrowser.map { RemoteFS.withoutPassword($0.root) }
        let origin = c.scrollOrigin
        return PaneLayout(
            url: url, columnRoot: root == url ? nil : root, props: c.model.props,
            filter: c.filterBar.filter.isActive ? c.filterBar.filter : nil, filterBarShown: !c.filterBar.isHidden,
            filterLocked: c.filterBar.isLocked, scroll: [Double(origin.x), Double(origin.y)])
    }

    /// Shows `layout` in this window: its tabs replace the open ones, and its panels show. `frame`: also move and
    /// size the window (session restoration; a workspace leaves the window where it is). False when the layout
    /// can't be applied (no tabs, a newer format); the window is then unchanged.
    @discardableResult
    func applyLayout(_ layout: WindowLayout, frame: Bool = false) -> Bool {
        guard let l = layout.normalized else { return false }
        if frame, let f = l.frame, let w = window {
            w.setFrame(w.constrainFrameRect(CGRect(x: f[0], y: f[1], width: f[2], height: f[3]), to: w.screen), display: false)
        }
        applyPanels(l.panels)
        tabHost.subviews.forEach { $0.removeFromSuperview() }
        tabs = []
        current = 0
        for t in l.tabs { addLayoutTab(t) }
        showTab(l.activeTab)
        AppDelegate.shared.sessionChanged()
        return true
    }

    private func applyPanels(_ p: PanelLayout) {
        p.sidebarWidth.map { PanelSize.sidebarWidth.restore(CGFloat($0)) }
        p.informationWidth.map { PanelSize.informationWidth.restore(CGFloat($0)) }
        p.terminalHeight.map { PanelSize.terminalHeight.restore(CGFloat($0)) }
        showPlaces = p.places
        showFolders = p.folders
        showInformation = p.information
        showTerminal = p.terminal
        showShelf = p.shelf
        rebuildPanels()
    }

    private func addLayoutTab(_ t: TabLayout) {
        let start = t.primary.columnRoot ?? t.primary.url, split = t.secondary.map { $0.columnRoot ?? $0.url }
        // A tab on a server connects when it's shown: an offline one shows its error (and Try Again) then, and a
        // workspace with several never asks for several passwords at once.
        let remote = ([start] + (split.map { [$0] } ?? [])).contains { LocationKind.of($0).isRemote }
        let tab = addTab(url: start, select: false, split: split, afterCurrent: false, loadsWhenShown: remote)
        tab.frame = tabHost.bounds
        tab.customTitle = t.title
        if let f = t.splitFraction { tab.setSplitShare(CGFloat(f)) }
        tab.layoutSubtreeIfNeeded()
        apply(t.primary, to: tab.primary)
        if let pane = t.secondary, let s = tab.secondary { apply(pane, to: s) }
        tab.setActive(secondary: t.activeIsSecondary)
        if t.linked, let s = tab.secondary {
            tab.linkedRoots = (tab.primary.url, s.url)
            tab.containers.forEach { $0.preservesMissingLocation = true }
        }
    }

    private func apply(_ pane: PaneLayout, to c: ViewContainer) {
        if let props = pane.props { c.model.showProps(props) }
        if pane.columnRoot != nil, pane.url != c.url {
            // The columns start at their root; then the focused column's folder opens among them.
            c.layoutSubtreeIfNeeded()
            c.setURL(pane.url, addToHistory: true)
            if let props = pane.props { c.model.showProps(props) }
        }
        c.filterBar.isLocked = pane.filterLocked
        if let f = pane.filter { c.filterBar.set(f) }
        c.filterBar.isHidden = !(pane.filterBarShown || pane.filter != nil)
        if let s = pane.scroll, s.count == 2, s.allSatisfy(\.isFinite) { c.restoreScroll(to: CGPoint(x: s[0], y: s[1])) }
        c.needsLayout = true
    }
}
