import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

/// Menu/shortcut actions (Dolphin's KActionCollection). Menu items target the first responder;
/// the window controller is in the responder chain. Validation, menus and context menus live in
/// the MainWindowActions+*.swift extensions.
extension MainWindowController {

    /// `representedObject` of "Paste Into Folder" (pastes into the selected folder instead of the view).
    static let pasteIntoFolder = "into"

    // MARK: Selection helpers

    var selectedURLs: [URL] { view.model.selectedItems.map(\.url) }
    var hasSelection: Bool { !view.model.selection.isEmpty }
    /// Selected items are all local files (tags, sharing, archives, Launch Services…).
    var selectionIsLocal: Bool { hasSelection && selectedURLs.allSatisfy(\.isFileURL) }
    /// Selected items can be cut, trashed or renamed: local files or SFTP/FTP/ADB items.
    var selectionIsManageable: Bool { hasSelection && selectedURLs.allSatisfy { $0.isFileURL || RemoteFS.isRemote($0) } }
    /// What "this" means for location-wide actions: the selection, else the current folder.
    var actionTargets: [URL] { hasSelection ? selectedURLs : [view.url] }

    var isTypingFocus: Bool {
        guard let fr = window?.firstResponder else { return false }
        return fr is NSTextView || fr === terminal.terminalView
    }

    /// New items can be created in the current folder.
    var writable: Bool {
        if RemoteFS.isRemote(view.url) { return true }
        guard view.url.isFileURL else { return false }
        if FileManager.default.isWritableFile(atPath: view.url.path) { return true }
        // Root-owned folders: allowed, the operation asks to authenticate (Finder). Read-only volumes: no. The mount
        // flags, since volumeIsReadOnly says false for the sealed system volume (/System, /usr).
        var fs = statfs()
        guard statfs(view.url.path, &fs) == 0 else { return false }
        return fs.f_flags & UInt32(MNT_RDONLY) == 0
    }

    /// Shows an error in the view's message bar.
    func reportError(_ text: String, in c: ViewContainer? = nil) {
        let c = c ?? view
        c.messageBar.show(text, error: true)
        c.needsLayout = true
    }

    // MARK: File

    @objc func newWindow(_ sender: Any?) { AppDelegate.shared.newWindow(at: view.url) }
    @objc func newTab(_ sender: Any?) { addTab(url: Settings.shared.homeURL) }
    @objc func closeCurrentTab(_ sender: Any?) { closeTab(current) }

    @objc func undoCloseTab(_ sender: Any?) {
        guard let t = closedTabs.popLast() else { return }
        addTab(url: t.url, split: t.split)
    }

    @objc func createFolder(_ sender: Any?) { createItem(.folder) }

    @objc func createFile(_ sender: NSMenuItem) {
        guard let kind = NewItemKind(rawValue: sender.tag) else { return }
        createItem(kind)
    }

    private func createItem(_ kind: NewItemKind) {
        guard writable else { return }
        if let p = RemoteFS.provider(for: view.url) { createRemote(folder: kind == .folder, provider: p); return }
        NewItemDialog.run(kind: kind, in: view.url, window: window) { [weak self] url in
            guard let self else { return }
            FileOperationsController.shared.pushUndo(.created([url]))
            self.view.pendingSelect = url
            self.view.reload()
        }
    }

    /// New folder / empty file on a remote location.
    private func createRemote(folder: Bool, provider p: RemoteProvider) {
        let a = NSAlert()
        a.messageText = folder ? "Create New Folder" : "Create New File"
        a.informativeText = "In \(view.url.absoluteString)"
        let f = NSTextField(string: folder ? "New Folder" : "New File.txt")
        f.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        let c = view
        a.runSheet(for: window) { [weak self] r in
            let name = f.stringValue
            guard r == .alertFirstButtonReturn, !name.isEmpty else { return }
            let target = c.url.appendingPathComponent(name)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if folder { try p.makeFolder(target) } else {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: tmp) }
                        let file = tmp.appendingPathComponent(name)
                        FileManager.default.createFile(atPath: file.path, contents: Data())
                        try p.upload(file, into: c.url)
                    }
                    DispatchQueue.main.async { c.pendingSelect = target; c.reload() }
                } catch {
                    DispatchQueue.main.async { self?.reportError(error.localizedDescription, in: c) }
                }
            }
        }
    }

    @objc func addToPlaces(_ sender: Any?) {
        if let f = view.model.selectedItems.first(where: \.isBrowsableFolder) { PlacesModel.shared.add(f.url) }
        else if view.url.isFileURL { PlacesModel.shared.add(view.url) }
    }

    @objc func renameItem(_ sender: Any?) {
        let items = view.model.selectedItems
        guard !items.isEmpty else { enterSelectionMode(prompt: "Select the file or folder that should be renamed."); return }
        if items.count == 1 && Settings.shared.renameInline { view.list.beginRename(items[0].url) } else { renameDialog(items) }
    }

    /// Rename dialog: one item, or several with "#" replaced by 1, 2, 3… (Dolphin's batch rename).
    private func renameDialog(_ items: [FileItem]) {
        let a = NSAlert()
        a.messageText = items.count == 1 ? "Rename Item" : "Rename Items"
        a.informativeText = items.count == 1 ? "Rename the item “\(items[0].name)” to:"
            : "Rename the \(items.count) selected items to:\n(# is replaced by ascending numbers)"
        let f = NSTextField(string: items.count == 1 ? items[0].name : "New name #")
        f.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        let c = view
        a.runSheet(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
            if items.count == 1 { self.rename(items[0], to: f.stringValue, in: c); return }
            self.batchRename(items, pattern: f.stringValue, in: c)
        }
    }

    private func batchRename(_ items: [FileItem], pattern raw: String, in c: ViewContainer) {
        let pattern = raw.contains("#") ? raw : raw + " #"
        var denied: [(URL, URL)] = []
        var failed: [String] = []
        for (i, it) in items.enumerated() {
            var name = pattern.replacingOccurrences(of: "#", with: String(i + 1))
            if !it.fileExtension.isEmpty { name += "." + it.fileExtension }
            if !it.url.isFileURL { rename(it, to: name, in: c); continue }   // remote: renamed in the background
            do {
                let new = try FileActions.rename(it.url, to: name)
                FileOperationsController.shared.pushUndo(.renamed(from: it.url, to: new))
            } catch where FileJob.isPermissionError(error) {
                denied.append((it.url, it.url.deletingLastPathComponent().appendingPathComponent(name)))
            } catch {
                failed.append("“\(it.name)”: \(error.localizedDescription)")
            }
        }
        if !denied.isEmpty {
            FileOperationsController.authorize(verb: "rename", items: denied.map(\.0),
                                               commands: denied.flatMap { FileOperationsController.renameCommands($0.0, to: $0.1) }, window: window)
        }
        if !failed.isEmpty { reportError("Could not rename " + failed.joined(separator: "; "), in: c) }
        c.reload()
    }

    @objc func duplicateItem(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be duplicated here."); return }
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        // Copies go next to their originals, which may sit in expanded subfolders or search results.
        let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
        for (folder, group) in groups {
            FileOperationsController.shared.run(.copy, group, to: folder, window: window) { [weak self] results in
                guard let self, let first = results.first else { return }
                if groups.count == 1 { self.view.model.selection = Set(results) }
                self.view.pendingSelect = first
                self.view.reload()
                if urls.count == 1 && results.count == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.view.list.beginRename(first) }
                }
            }
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        if view.list.isRenaming { return }
        if NSEvent.modifierFlags.contains(.shift) { deleteItem(sender); return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be moved to the Trash."); return }
        FileOperationsController.shared.trash(selectedURLs, window: window)
    }

    @objc func deleteItem(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be permanently deleted."); return }
        FileOperationsController.shared.delete(selectedURLs, window: window)
    }

    @objc func properties(_ sender: Any?) { PropertiesWindow.show(urls: actionTargets) }

    @objc func restoreFromTrash(_ sender: Any?) {
        let unknown = FileOperationsController.shared.restore(selectedURLs, window: window)
        view.reload()
        guard !unknown.isEmpty else { return }
        // Items trashed by other apps: ask where to put them.
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Restore Here"
        p.message = unknown.count == 1 ? "The original location of “\(unknown[0].lastPathComponent)” is unknown. Choose where to restore it."
            : "The original location of \(unknown.count) items is unknown. Choose where to restore them."
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        runPanel(p) { [weak self] dir in FileOperationsController.shared.run(.move, unknown, to: dir, window: self?.window) }
    }

    // MARK: Edit

    @objc func undoFileOperation(_ sender: Any?) { FileOperationsController.shared.undo(window: window); view.reload() }
    @objc func redoFileOperation(_ sender: Any?) { FileOperationsController.shared.redo(window: window); view.reload() }

    @objc func cut(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be cut."); return }
        FileOperationsController.shared.copy(selectedURLs, cut: true)
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { enterSelectionMode(prompt: "Select the files and folders that should be copied."); return }
        FileOperationsController.shared.copy(urls, cut: false)
        view.statusBar.showMessage(urls.count == 1 ? "Copied “\(urls[0].lastPathComponent)”." : "Copied \(urls.count) items.")
    }

    /// Paths of local items; full URLs (sftp://…, recent:/…) for everything else.
    @objc func copyLocation(_ sender: Any?) {
        let locations = actionTargets.map { $0.isFileURL ? $0.path : $0.absoluteString }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(locations.joined(separator: "\n"), forType: .string)
        view.statusBar.showMessage("Copied the location to the clipboard.")
    }

    @objc func paste(_ sender: Any?) {
        var target = view.url
        let sel = view.model.selectedItems
        if (sender as? NSMenuItem)?.representedObject as? String == Self.pasteIntoFolder, sel.count == 1, sel[0].isBrowsableFolder {
            target = sel[0].url
        }
        let c = view
        FileOperationsController.shared.paste(into: target, window: window) { results in
            c.model.selection = Set(results)
            if let f = results.first { c.pendingSelect = f }
            c.reload()
        }
    }

    @objc func showFilterBar(_ sender: Any?) {
        if !view.filterBar.isHidden && window?.firstResponder === view.filterBar.field.currentEditor() {
            view.filterBarClosed(view.filterBar)
        } else {
            view.showFilterBar()
        }
    }

    @objc func showSearch(_ sender: Any?) {
        if !view.searchBar.isHidden && sender is FlatButton { view.searchBarClosed(view.searchBar) } else { view.showSearch() }
        syncToActiveView()
    }

    @objc override func selectAll(_ sender: Any?) {
        view.model.selection = Set(view.model.rows.map(\.item.url))
        view.list.needsDisplay = true
    }

    @objc func invertSelection(_ sender: Any?) {
        let all = Set(view.model.rows.map(\.item.url))
        view.model.selection = all.subtracting(view.model.selection)
        view.list.needsDisplay = true
    }

    @objc func toggleSelectionMode(_ sender: Any?) {
        view.selectionMode.toggle()
        window?.makeFirstResponder(view.list)
    }

    /// Actions triggered with nothing selected enter selection mode with a prompt (Dolphin 23.08+).
    private func enterSelectionMode(prompt: String) {
        view.selectionMode = true
        view.selectionTop.prompt = prompt
        window?.makeFirstResponder(view.list)
    }

    @objc func copyToOtherView(_ sender: Any?) {
        guard let other = tab.inactive else { return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be copied to the other view."); return }
        FileOperationsController.shared.run(.copy, selectedURLs, to: other.url, window: window)
    }

    @objc func moveToOtherView(_ sender: Any?) {
        guard let other = tab.inactive else { return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be moved to the other view."); return }
        FileOperationsController.shared.run(.move, selectedURLs, to: other.url, window: window)
    }

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

    // MARK: Go

    @objc func goUp(_ sender: Any?) { view.goUp() }
    @objc func goBack(_ sender: Any?) {
        if window?.firstResponder is NSTextView { return }
        view.goBack()
    }
    @objc func goForward(_ sender: Any?) { view.goForward() }
    @objc func goHome(_ sender: Any?) { view.setURL(Settings.shared.homeURL) }
    @objc func goNetwork(_ sender: Any?) { view.setURL(NetworkBrowser.url) }
    @objc func connectToServer(_ sender: Any?) { AddNetworkFolderDialog.run(window: window) }
    @objc func goToPlace(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { view.setURL(u) }
    }

    // MARK: Tools

    /// Local folders "Open Terminal" acts on: the selected folders, else the current one.
    var terminalFolders: [URL] {
        let sel = view.model.selectedItems.filter(\.isBrowsableFolder)
        return (sel.isEmpty ? [view.url] : sel.map(\.url)).filter(\.isFileURL)
    }

    /// Tools › Open Terminal (⇧F4): a terminal in the current folder, whatever is selected.
    @objc func openTerminal(_ sender: Any?) {
        guard view.url.isFileURL else { return }
        ExternalTerminal.open(at: view.url)
    }

    /// Open Terminal Here (⌥⇧F4, context menus): one terminal per selected folder, else the current folder.
    @objc func openTerminalHere(_ sender: Any?) {
        let dirs = terminalFolders
        guard !dirs.isEmpty else { return }
        guard dirs.count > 3 && Settings.shared.confirmManyTerminals else { dirs.forEach(ExternalTerminal.open(at:)); return }
        let a = NSAlert()
        a.messageText = "Are you sure you want to open \(dirs.count) terminals?"
        a.addButton(withTitle: "Open Terminals")
        a.addButton(withTitle: "Cancel")
        a.runSheet(for: window) { r in if r == .alertFirstButtonReturn { dirs.forEach(ExternalTerminal.open(at:)) } }
    }

    @objc func quickLook(_ sender: Any?) {
        guard let p = QLPreviewPanel.shared() else { return }
        if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = actionTargets.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func emptyTrash(_ sender: Any?) { FileOperationsController.shared.emptyTrash(window: window) }

    @objc func shareItems(_ sender: Any?) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard let first = urls.first else { return }
        let picker = NSSharingServicePicker(items: urls)
        let r = view.list.rect(for: first) ?? view.list.visibleRect
        picker.show(relativeTo: r, of: view.list, preferredEdge: .maxY)
    }

    @objc func setTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        toggleTag(tag)
    }

    static func tagNames(of url: URL) -> [String] { (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] }

    /// Adds the tag to every selected item, or removes it if they all have it (Finder).
    func toggleTag(_ tag: String) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let all = urls.allSatisfy { Self.tagNames(of: $0).contains(tag) }
        for u in urls {
            var tags = Self.tagNames(of: u)
            tags.removeAll { $0 == tag }
            if !all { tags.append(tag) }
            try? (u as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        view.model.refreshTags()
        view.list.needsDisplay = true
    }

    @objc func cloudDownload(_ sender: Any?) { CloudActions.download(selectedURLs) }
    @objc func cloudEvict(_ sender: Any?) { CloudActions.evict(selectedURLs, window: window) }

    /// Zips the selection next to it: "<name>.zip" for one item, "Archive.zip" for several.
    @objc func compress(_ sender: Any?) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let folder = Self.commonFolder(of: urls)
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var zipName = "\(base).zip"
        var n = 2
        while existing.contains(zipName) { zipName = "\(base) \(n).zip"; n += 1 }
        let zip = folder.appendingPathComponent(zipName)
        let p = Process()
        p.currentDirectoryURL = folder
        if urls.count == 1 {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, zip.path]
        } else {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            // "./name": names starting with "-" must not be read as zip options.
            p.arguments = ["-r", "-q", "./" + zipName] + urls.map { "./" + String($0.path.dropFirst(prefix.count)) }
        }
        runTool(p, failure: "Could not create “\(zipName)”.", select: zip)
    }

    /// Unpacks the selected archive into a new folder next to it, named after it ("<name>", "<name> 2"…), so
    /// nothing already there is ever overwritten (Ark's "Extract here, autodetect subfolder" without the guessing).
    @objc func extractHere(_ sender: Any?) {
        guard let it = view.model.selectedItems.first, it.url.isFileURL else { return }
        let parent = it.url.deletingLastPathComponent()
        var base = it.url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }   // name.tar.gz
        if base.isEmpty { base = "Archive" }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
        var name = base
        var n = 2
        while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
        let dest = parent.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false) } catch {
            reportError("Could not extract “\(it.name)”: \(error.localizedDescription)"); return
        }
        let p = Process()
        if it.fileExtension.lowercased() == "zip" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", it.url.path, dest.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xf", it.url.path, "-C", dest.path]
        }
        // A failed extraction leaves no empty folder behind (a partial one is kept: it may hold what could be read).
        runTool(p, failure: "Could not extract “\(it.name)”.", select: dest) {
            if ((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty { try? FileManager.default.removeItem(at: dest) }
        }
    }

    /// Deepest folder containing all `urls` (their shared parent in the usual case).
    static func commonFolder(of urls: [URL]) -> URL {
        var parts = urls[0].deletingLastPathComponent().standardizedFileURL.pathComponents
        for u in urls.dropFirst() {
            let other = u.deletingLastPathComponent().standardizedFileURL.pathComponents
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: parts.isEmpty ? ["/"] : parts), isDirectory: true)
    }

    /// Runs an archiver in the background, then reloads the view (and reports failures).
    private func runTool(_ p: Process, failure: String, select: URL?, onFailure: (() -> Void)? = nil) {
        let c = view
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 { onFailure?(); self?.reportError(failure, in: c) } else if let select { c.pendingSelect = select }
                c.reload()
            }
        }
        do { try p.run() } catch { onFailure?(); reportError("\(failure) \(error.localizedDescription)", in: c) }
    }

    // MARK: Tabs

    @objc func nextTab(_ sender: Any?) { if tabs.count > 1 { showTab((current + 1) % tabs.count) } }
    @objc func previousTab(_ sender: Any?) { if tabs.count > 1 { showTab((current - 1 + tabs.count) % tabs.count) } }
    /// ⌥1…⌥9 pick a tab; ⌥0 (tag 0) the last one.
    @objc func activateTab(_ sender: NSMenuItem) {
        let i = sender.tag == 0 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(i) { showTab(i) }
    }
}

// MARK: - Quick Look (Mac addition, bound to Space)

extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    private var quickLookURLs: [URL] {
        let sel = selectedURLs
        if !sel.isEmpty { return sel }
        return view.model.currentURL.map { [$0] } ?? []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // The selection can change between the count and this call.
        quickLookURLs[safe: index].map { $0 as NSURL }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let u = item.previewItemURL, let r = view.list.iconScreenRect(for: u) else { return .zero }
        return r
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown { view.list.keyDown(with: event); panel.reloadData(); return true }
        return false
    }
}
