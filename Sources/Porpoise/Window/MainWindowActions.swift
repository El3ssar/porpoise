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
            FileOperationsController.shared.authorize(verb: "rename", items: denied.map(\.0),
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

    // MARK: Tabs

    @objc func nextTab(_ sender: Any?) { if tabs.count > 1 { showTab((current + 1) % tabs.count) } }
    @objc func previousTab(_ sender: Any?) { if tabs.count > 1 { showTab((current - 1 + tabs.count) % tabs.count) } }
    /// ⌥1…⌥9 pick a tab; ⌥0 (tag 0) the last one.
    @objc func activateTab(_ sender: NSMenuItem) {
        let i = sender.tag == 0 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(i) { showTab(i) }
    }
}
