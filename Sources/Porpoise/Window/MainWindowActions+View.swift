import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    // MARK: View

    @objc func zoomIn(_ sender: Any?) { view.zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { view.zoom(by: -1) }
    @objc func zoomReset(_ sender: Any?) { mutateProps { $0.resetIconSize(for: $0.mode) } }

    @objc func setViewMode(_ sender: NSMenuItem) {
        guard let m = ViewMode.allCases[safe: sender.tag] else { return }
        view.setMode(m)
        syncToActiveView()
    }

    func cycleViewMode() {
        let all = ViewMode.allCases
        let i = all.firstIndex(of: view.model.props.mode) ?? 0
        view.setMode(all[(i + 1) % all.count])
        syncToActiveView()
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let role = ItemRole(rawValue: raw) else { return }
        mutateProps { $0.sortRole = role }
    }

    @objc func setSortAscending(_ sender: Any?) { mutateProps { $0.sortOrder = .ascending } }
    @objc func setSortDescending(_ sender: Any?) { mutateProps { $0.sortOrder = .descending } }
    @objc func toggleFoldersFirst(_ sender: Any?) { mutateProps { $0.foldersFirst.toggle() } }
    @objc func toggleHiddenLast(_ sender: Any?) { mutateProps { $0.hiddenLast.toggle() } }

    @objc func groupBy(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String
        mutateProps { p in
            p.groupSameAsSort = raw == "same"
            p.groupRole = raw.flatMap { ItemRole(rawValue: $0) }
        }
    }

    @objc func toggleAdditionalRole(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let role = ItemRole(rawValue: raw) else { return }
        mutateProps { p in
            var roles = p.roles(for: p.mode)
            if let i = roles.firstIndex(of: role) { roles.remove(at: i) } else { roles.append(role) }
            p.setRoles(roles, for: p.mode)
        }
    }

    @objc func togglePreviews(_ sender: Any?) { mutateProps { $0.previews.toggle() } }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        mutateProps { $0.showHidden.toggle() }
        view.statusBar.showMessage(view.model.props.showHidden ? "Hidden files are shown." : "Hidden files are hidden.")
    }

    /// Restore to Defaults: the folder's built-in style (Downloads by date…) when styles are remembered per folder;
    /// with the common style, the plain defaults (a folder's special defaults would become everyone's style).
    @objc func restoreViewDefaults(_ sender: Any?) {
        let perFolder = Settings.shared.rememberPerFolder
        mutateProps { [url = view.url] in $0 = perFolder ? ViewProperties.defaults(for: url) : ViewProperties() }
    }

    @objc func adjustViewStyle(_ sender: Any?) {
        AdjustViewDialog.run(for: view, window: window) { [weak self] in self?.syncToActiveView() }
    }

    /// Changes the active view's properties, saves them and refreshes the toolbar.
    private func mutateProps(_ f: (inout ViewProperties) -> Void) {
        var p = view.model.props
        f(&p)
        view.model.props = p
        view.model.saveProps()
        syncToActiveView()
    }

    @objc func toggleSplit(_ sender: Any?) {
        if tab.isSplit {
            tab.closeSplit()
        } else {
            tab.openSplit()
            if let s = tab.secondary {
                s.delegate = self
                tab.navigators[1].url = s.url
            }
        }
        syncToActiveView()
        window?.makeFirstResponder(view.list)
    }

    @objc func splitToTabs(_ sender: Any?) {
        guard let s = tab.secondary else { return }
        let u = s.url
        tab.closeSplit(closeActive: false)
        tab.setActive(secondary: false)
        addTab(url: u)
    }

    @objc func popOutSplit(_ sender: Any?) {
        guard tab.isSplit else { return }
        let u = view.url
        tab.closeSplit(closeActive: true)
        syncToActiveView()
        AppDelegate.shared.newWindow(at: u)
    }

    @objc func focusOtherView(_ sender: Any?) {
        guard tab.isSplit else { return }
        focusPane(secondary: !tab.activeIsSecondary)
    }

    @objc func reloadView(_ sender: Any?) { view.reload() }

    /// ⌥← / ⌥→: move focus to the left / right pane of a split view.
    @objc func focusLeftPane(_ sender: Any?) { focusPane(secondary: false) }
    @objc func focusRightPane(_ sender: Any?) { focusPane(secondary: true) }

    private func focusPane(secondary: Bool) {
        guard tab.isSplit, tab.activeIsSecondary != secondary else { return }
        tab.setActive(secondary: secondary)
        window?.makeFirstResponder(view.list)
        syncToActiveView()
    }

    /// Tags follow `panelToggles`: Places, Information, Folders, Terminal.
    @objc func togglePanel(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: animatePanel(.sidebar, show: !showPlaces) { self.showPlaces.toggle() }
        case 1: animatePanel(.information, show: !showInformation) { self.showInformation.toggle() }
        case 2: animatePanel(.sidebar, show: !showFolders) { self.showFolders.toggle() }
        default:
            let show = !showTerminal
            animatePanel(.terminal, show: show) { self.showTerminal.toggle() }
            if show { DispatchQueue.main.async { self.window?.makeFirstResponder(self.terminal.terminalView) } }
            else { window?.makeFirstResponder(view.list) }
        }
    }

    /// Toggles keyboard focus between the Places panel and the active view.
    @objc func focusPlaces(_ sender: Any?) {
        if window?.firstResponder === places { window?.makeFirstResponder(view.list); return }
        if !showPlaces { showPlaces = true; rebuildPanels() }
        window?.makeFirstResponder(places)
    }

    @objc func focusTerminal(_ sender: Any?) {
        if !showTerminal { showTerminal = true; rebuildPanels() }
        if window?.firstResponder === terminal.terminalView { window?.makeFirstResponder(view.list) }
        else { window?.makeFirstResponder(terminal.terminalView) }
    }

    private var activeNavigator: BreadcrumbView { tab.navigators[tab.activeIsSecondary ? 1 : 0] }

    @objc func editLocation(_ sender: Any?) {
        let n = activeNavigator
        if n.isEditing { n.endEditing(); window?.makeFirstResponder(view.list) } else { n.beginEditing(selectAll: false) }
    }

    @objc func replaceLocation(_ sender: Any?) { activeNavigator.beginEditing(selectAll: true) }
}
