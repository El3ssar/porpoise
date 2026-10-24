import AppKit
import PorpoiseCore
import PorpoiseServices

/// Menu/shortcut actions (Dolphin's KActionCollection). Menu items target the first responder;
/// the window controller is in the responder chain. Validation, menus and context menus live in
/// the MainWindowActions+*.swift extensions.
extension MainWindowController {

    /// `representedObject` of "Paste Into Folder" (pastes into the selected folder instead of the view).
    static let pasteIntoFolder = "into"

    // MARK: Selection helpers

    var selectedURLs: [URL] { view.model.selectedSnapshot.urls }
    var hasSelection: Bool { !view.model.selection.isEmpty }
    /// Selected items are all local files (tags, sharing, archives, Launch Services…).
    var selectionIsLocal: Bool { hasSelection && view.model.selectedSnapshot.isLocal }
    /// Selected items can be cut, trashed or renamed: local files or SFTP/FTP/ADB items.
    var selectionIsManageable: Bool {
        hasSelection && view.model.selectedSnapshot.isManageable
    }
    /// What "this" means for location-wide actions: the selection, else the current folder.
    var actionTargets: [URL] { hasSelection ? selectedURLs : [view.url] }

    var isTypingFocus: Bool {
        guard let fr = window?.firstResponder else { return false }
        return fr is NSTextView || fr === terminal.terminalView
    }

    /// New items can be created in the current folder.
    var writable: Bool {
        if PlacesModel.isCloud(view.url) { return CloudAccounts.shared.denial(.addItems, folder: view.url) == nil }
        return LocationOperations(for: view.url).canAddItems(view.url)
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

    @objc func createFromTemplate(_ sender: Any?) {
        guard writable, view.url.isFileURL else { return }
        TemplateWindow(folder: view.url) { [weak self] url in
            FileOperationsController.shared.pushUndo(.created([url]))
            FileOperationsController.notifyChanged([url])
            guard let self, self.view.url.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else { return }
            self.view.pendingSelect = url; self.view.reload()
        }.present()
    }

    @objc func createFile(_ sender: NSMenuItem) {
        guard let kind = NewItemKind(rawValue: sender.tag) else { return }
        createItem(kind)
    }

    private func createItem(_ kind: NewItemKind) {
        // Cloud folders: say why not, rather than ignoring the shortcut.
        if PlacesModel.isCloud(view.url) { if kind == .folder { createCloudFolder() }; return }
        guard writable else { return }
        if RemoteFS.isRemote(view.url) { createRemote(kind); return }
        NewItemDialog.run(kind: kind, in: view.url, window: window) { [weak self] url in
            guard let self else { return }
            FileOperationsController.shared.pushUndo(.created([url]))
            self.view.pendingSelect = url
            self.view.reload()
        }
    }

    /// New folder or empty file on a server or device: a name nothing in the folder has, and Undo removes it again
    /// while it is still empty. Links can't be made there: they are empty files.
    private func createRemote(_ kind: NewItemKind) {
        let c = view
        let folder = kind == .folder
        let place = c.url.host.map { "\($0)\(c.url.path)" } ?? c.url.path
        let shown: NewItemKind = kind == .link || kind == .urlLink ? .emptyFile : kind
        NewItemDialog.runNamed(
            shown, in: c.url, title: place.removingPercentEncoding ?? place, names: Set(c.model.items.map(\.name)), window: window
        ) { [weak self] name in
            let target = c.url.appendingPathComponent(name)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    let operations = LocationOperations(for: c.url)
                    return folder ? try operations.makeFolder(target) : try operations.makeEmptyFile(target)
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let undo):
                        FileOperationsController.shared.pushUndo(undo)
                        c.pendingSelect = target; c.reload()
                    case .failure(let error): self?.reportError(error.localizedDescription, in: c)
                    }
                }
            }
        }
    }

    @objc func addToPlaces(_ sender: Any?) {
        if let f = view.model.selectedItems.first(where: \.isBrowsableFolder) {
            // Cloud folders are named by their ids in the URL: the place takes the folder's name.
            PlacesModel.shared.add(f.url, title: PlacesModel.isCloud(f.url) ? f.name : nil)
        } else if view.url.isFileURL {
            PlacesModel.shared.add(view.url)
        } else if PlacesModel.isCloud(view.url) {
            PlacesModel.shared.add(view.url, title: view.url.folderName)
        }
    }

    @objc func renameItem(_ sender: Any?) {
        let items = view.model.selectedItems
        guard !items.isEmpty else { enterSelectionMode(prompt: "Select the file or folder that should be renamed."); return }
        if items.count > 1 {
            let container = view
            BatchRenameDialog.run(items.map(\.url), window: window) { [weak container] urls in
                container?.pendingSelect = urls.first; container?.reload()
            }
        } else if Settings.shared.renameInline {
            view.list.beginRename(items[0].url)
        } else {
            renameDialog(items[0])
        }
    }

    private func renameDialog(_ item: FileItem) {
        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = "Rename the item “\(item.name)” to:"
        let field = NSTextField(string: item.name)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let container = view
        alert.runSheet(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            self?.rename(item, to: field.stringValue, in: container)
        }
    }

    @objc func duplicateItem(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be duplicated here."); return }
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        // Copies go next to their originals, which may sit in expanded subfolders or search results.
        let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
        // The view that asked, even if another tab or pane is active when the copy ends.
        let c = view, visit = view.visits, acted = view.list.userActions
        for (folder, group) in groups {
            FileOperationsController.shared.run(.copy, group, to: folder, window: window) { [weak c] results in
                guard let c, let first = results.first else { return }
                if groups.count == 1 { c.model.selection = Set(results) }
                c.pendingSelect = first
                // Not in a pane that went elsewhere or was used meanwhile.
                if urls.count == 1 && results.count == 1 && c.visits == visit && c.list.userActions == acted {
                    c.pendingRename = (first, acted)
                }
                c.reload()
            }
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        if view.list.isRenaming { return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be moved to the Trash."); return }
        fileOperations.trash(selectedURLs, window: window)
    }

    /// Opt-in App Cleanup: reviews the selected apps' Library files (all unchecked) before moving them to the Trash.
    @objc func removeAppAndLeftovers(_ sender: Any?) {
        guard selectedURLs.contains(where: FileOperationsController.isApplication) else { return }
        FileOperationsController.shared.trash(selectedURLs, window: window, reviewingLeftovers: true)
    }

    @objc func deleteItem(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be permanently deleted."); return }
        fileOperations.delete(selectedURLs, window: window)
    }

    @objc func properties(_ sender: Any?) {
        PropertiesWindow.show(urls: actionTargets, items: view.model.selectedItems, showingHidden: view.model.props.showHidden)
    }

    @objc func restoreFromTrash(_ sender: Any?) {
        let unknown = FileOperationsController.shared.restore(selectedURLs, window: window)
        view.reload()
        guard !unknown.isEmpty else { return }
        // Items trashed by other apps: ask where to put them.
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Restore Here"
        p.message =
            unknown.count == 1
            ? "The original location of “\(unknown[0].lastPathComponent)” is unknown. Choose where to restore it."
            : "The original location of \(unknown.count) items is unknown. Choose where to restore them."
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        runPanel(p) { [weak self] dir in FileOperationsController.shared.run(.move, unknown, to: dir, window: self?.window) }
    }

    // MARK: Go

    @objc func goUp(_ sender: Any?) { view.goUp() }
    @objc func goBack(_ sender: Any?) { view.goBack() }
    @objc func goForward(_ sender: Any?) { view.goForward() }
    @objc func goHome(_ sender: Any?) { view.setURL(Settings.shared.homeURL) }
    @objc func goNetwork(_ sender: Any?) { view.setURL(NetworkBrowser.url) }
    @objc func connectToServer(_ sender: Any?) { ConnectSheet.run(window: window) { [weak self] in self?.view.setURL($0) } }
    @objc func showConnections(_ sender: Any?) { ConnectionsWindow.show { [weak self] in self?.view.setURL($0) } }
    @objc func goToPlace(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { view.setURL(u) }
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
