import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    // MARK: View

    @objc func zoomIn(_ sender: Any?) { view.zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { view.zoom(by: -1) }
    @objc func zoomReset(_ sender: Any?) {
        if view.showsApps, let g = view.apps?.grid { return g.animateZoom(to: AppsGridView.defaultIconSize) }
        mutateProps { $0.resetIconSize(for: $0.mode) }
    }

    @objc func setViewMode(_ sender: NSMenuItem) {
        guard !view.showsAirDrop else { return }
        guard let m = ViewMode.allCases[safe: sender.tag] else { return }
        show(m)
    }

    /// The active pane in mode `m`; Column view leaves it alone in the tab.
    func show(_ m: ViewMode) {
        if m == .columns { tab.keepAlone(view) }
        view.setMode(m)
        syncToActiveView()
    }

    func cycleViewMode() {
        let all = ViewMode.allCases
        let i = all.firstIndex(of: view.model.props.mode) ?? 0
        show(all[(i + 1) % all.count])
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

    /// Column view's preview column for a selected file, on or off (every window).
    @objc func togglePreviewColumn(_ sender: Any?) { Settings.shared.columnsShowPreview.toggle() }

    /// View › Hide/Show Status Bar (⌘/, as in Finder): hides it, and brings back the style it had.
    @objc func toggleStatusBar(_ sender: Any?) {
        let s = Settings.shared
        if s.statusBarMode == .disabled {
            s.statusBarMode = s.statusBarShownMode == .disabled ? .fullWidth : s.statusBarShownMode
        } else {
            s.statusBarShownMode = s.statusBarMode
            s.statusBarMode = .disabled
        }
    }

    /// View › Always Show Tab Bar (Settings › General › Tabs): the tab bar even with one tab.
    @objc func toggleTabBar(_ sender: Any?) { Settings.shared.alwaysShowTabBar.toggle() }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        mutateProps { $0.showHidden.toggle() }
        view.statusBar.showMessage(view.model.props.showHidden ? "Hidden files are shown." : "Hidden files are hidden.")
    }

    /// Restore to Defaults: the folder's built-in style (Downloads by date…) when styles are remembered per folder;
    /// with the common style, the plain defaults (a folder's special defaults would become everyone's style).
    @objc func restoreViewDefaults(_ sender: Any?) {
        mutateProps { [url = view.url] in $0 = ViewStyleStore().style(for: url, restoringDefaults: true) }
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
        // The right view goes to the new tab, so it's the one closed here, whichever view is active.
        tab.closeSplit(closeActive: tab.activeIsSecondary)
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

    @objc func reloadView(_ sender: Any?) {
        // In a cloud folder Reload also asks the service what changed elsewhere (other folders follow by themselves).
        if PlacesModel.isCloud(view.url) { CloudAccounts.shared.checkForChanges(in: view.url) }
        view.reload()
    }

    /// ⌥← / ⌥→: move focus to the left / right pane of a split view.
    @objc func focusLeftPane(_ sender: Any?) { focusPane(secondary: false) }
    @objc func focusRightPane(_ sender: Any?) { focusPane(secondary: true) }

    private func focusPane(secondary: Bool) {
        guard tab.isSplit, tab.activeIsSecondary != secondary else { return }
        tab.setActive(secondary: secondary)
        window?.makeFirstResponder(view.list)
        syncToActiveView()
    }

    /// Tags follow `panelToggles`: Places, Information, Folders, Terminal, Shelf.
    @objc func togglePanel(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: animatePanel(.sidebar, show: !showPlaces) { self.showPlaces.toggle() }
        case 1: animatePanel(.information, show: !showInformation) { self.showInformation.toggle() }
        case 2: animatePanel(.sidebar, show: !showFolders) { self.showFolders.toggle() }
        case 4: animatePanel(.sidebar, show: !showShelf) { self.showShelf.toggle() }
        default:
            let show = !showTerminal
            animatePanel(.terminal, show: show) { self.showTerminal.toggle() }
            if show {
                DispatchQueue.main.async { self.window?.makeFirstResponder(self.terminal.terminalView) }
            } else {
                window?.makeFirstResponder(view.list)
            }
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
        if window?.firstResponder === terminal.terminalView {
            window?.makeFirstResponder(view.list)
        } else {
            window?.makeFirstResponder(terminal.terminalView)
        }
    }

    private var activeNavigator: BreadcrumbView { tab.navigators[tab.activeIsSecondary ? 1 : 0] }

    @objc func editLocation(_ sender: Any?) {
        let n = activeNavigator
        if n.isEditing { n.endEditing(); window?.makeFirstResponder(view.list) } else { n.beginEditing(selectAll: false) }
    }

    @objc func replaceLocation(_ sender: Any?) { activeNavigator.beginEditing(selectAll: true) }
}
