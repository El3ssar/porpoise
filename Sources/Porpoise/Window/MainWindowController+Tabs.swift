import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Tabs

extension MainWindowController {
    @discardableResult
    func addTab(url: URL, select: Bool = true, split: URL? = nil, afterCurrent: Bool = true) -> PorpoiseTab {
        let t = PorpoiseTab(url: url)
        t.primary.delegate = self
        for (i, n) in t.navigators.enumerated() {
            n.delegate = self
            n.places = PlacesModel.shared.allEntries
            n.showPlacesButton = !showPlaces
            n.url = i == 0 ? url : (split ?? url)
        }
        let at = (afterCurrent && !Settings.shared.openNewTabsAtEnd && !tabs.isEmpty) ? current + 1 : tabs.count
        tabs.insert(t, at: at)
        if let s = split { t.openSplit(url: s, animated: false); t.setActive(secondary: false) }
        if select { showTab(at) } else { if at <= current && tabs.count > 1 { current += 1 }; updateTabBar() }
        return t
    }

    func showTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        tabHost.subviews.forEach { $0.removeFromSuperview() }
        current = i
        let t = tabs[i]
        t.frame = tabHost.bounds
        t.autoresizingMask = [.width, .height]
        tabHost.addSubview(t)
        updateTabBar()
        layoutRoot()
        syncToActiveView()
        window?.makeFirstResponder(view.list)
    }

    func updateTabBar() {
        tabBar.titles = tabs.map(\.title)
        tabBar.icons = tabs.map(\.iconName)
        tabBar.selected = current
        tabBar.isHidden = !tabBarVisible
        centerColumn.needsLayout = true
        root.needsLayout = true
    }

    func closeTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        rememberClosed(tabs.remove(at: i))
        if current >= tabs.count { current = tabs.count - 1 } else if i < current { current -= 1 }
        showTab(current)
    }

    /// Recently closed tabs kept for Undo Close Tab.
    private static let maxClosedTabs = 10

    private func rememberClosed(_ t: PorpoiseTab) {
        closedTabs.append((t.primary.url, t.secondary?.url))
        if closedTabs.count > Self.maxClosedTabs { closedTabs.removeFirst() }
    }

    /// Closes several tabs at once; the current tab stays selected if it survives, otherwise `fallback`.
    private func closeTabs(_ doomed: [PorpoiseTab], fallback: PorpoiseTab) {
        let wasCurrent = tab
        doomed.forEach(rememberClosed)
        tabs.removeAll { t in doomed.contains { $0 === t } }
        let selected = tabs.contains { $0 === wasCurrent } ? wasCurrent : fallback
        showTab(tabs.firstIndex { $0 === selected } ?? 0)
    }

    // MARK: - TabBarDelegate

    func tabBar(_ bar: TabBarView, select index: Int) { showTab(index) }
    func tabBar(_ bar: TabBarView, close index: Int) { closeTab(index) }
    func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?) {
        addTab(url: index.map { tabs[$0].active.url } ?? Settings.shared.homeURL)
    }
    func tabBar(_ bar: TabBarView, move from: Int, to: Int) {
        let wasCurrent = tab
        tabs.insert(tabs.remove(at: from), at: to)
        current = tabs.firstIndex { $0 === wasCurrent } ?? to
        updateTabBar()
    }
    func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int) {
        FileOperationsController.shared.handleDrop(urls, onto: tabs[index].active.url, operation: .generic, in: tabBar)
    }
    func tabBar(_ bar: TabBarView, detach index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let wasCurrent = tab
        let t = tabs.remove(at: index)
        AppDelegate.shared.newWindow(at: t.primary.url, split: t.secondary?.url)
        showTab(tabs.firstIndex { $0 === wasCurrent } ?? min(index, tabs.count - 1))
    }
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ icon: String, _ sel: Selector) {
            let it = m.addItem(withTitle: t, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = index
            it.image = Icons.shared.menuIcon(icon)
        }
        add("New Tab", "tab-new", #selector(tabMenuNew(_:)))
        add("Detach Tab", "tab-detach", #selector(tabMenuDetach(_:)))
        add("Rename Tab…", "edit-rename", #selector(tabMenuRename(_:)))
        m.addItem(.separator())
        add("Close Other Tabs", "tab-close-other", #selector(tabMenuCloseOthers(_:)))
        add("Close Tabs to the Left", "tab-close-other", #selector(tabMenuCloseLeft(_:)))
        add("Close Tabs to the Right", "tab-close-other", #selector(tabMenuCloseRight(_:)))
        add("Close Tab", "tab-close", #selector(tabMenuClose(_:)))
        return m
    }
    @objc private func tabMenuNew(_ s: NSMenuItem) { addTab(url: Settings.shared.homeURL) }
    @objc private func tabMenuDetach(_ s: NSMenuItem) { tabBar(tabBar, detach: s.tag) }
    @objc private func tabMenuClose(_ s: NSMenuItem) { closeTab(s.tag) }
    @objc private func tabMenuCloseOthers(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        let keep = tabs[s.tag]
        closeTabs(tabs.filter { $0 !== keep }, fallback: keep)
    }
    @objc private func tabMenuCloseLeft(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        closeTabs(Array(tabs[..<s.tag]), fallback: tabs[s.tag])
    }
    @objc private func tabMenuCloseRight(_ s: NSMenuItem) {
        guard tabs.indices.contains(s.tag) else { return }
        closeTabs(Array(tabs[(s.tag + 1)...]), fallback: tabs[s.tag])
    }
    @objc private func tabMenuRename(_ s: NSMenuItem) {
        let a = NSAlert()
        a.messageText = "Rename Tab"
        a.informativeText = "New tab name:"
        let f = NSTextField(string: tabs[s.tag].title)
        f.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            tabs[s.tag].customTitle = f.stringValue.isEmpty ? nil : f.stringValue
            updateTabBar()
        }
    }
}
