import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

extension MainWindowController {
    @objc func showChecksums(_ sender: Any?) {
        let urls = actionTargets.filter(\.isFileURL); if !urls.isEmpty { ChecksumWindow(roots: urls).present() }
    }
    @objc func showDiskUsage(_ sender: Any?) {
        let urls = actionTargets.filter(\.isFileURL); if !urls.isEmpty { DiskUsageWindow(roots: urls).present() }
    }
    @objc func showDuplicates(_ sender: Any?) {
        let urls = actionTargets.filter(\.isFileURL); if !urls.isEmpty { DuplicateWindow(roots: urls).present() }
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
        if spacePreview?.isVisible == true { spacePreview?.close(); return }
        showSpacePreview()
    }

    @objc func emptyTrash(_ sender: Any?) { FileOperationsController.shared.emptyTrash(window: window) }

    /// Edit › Add to Shelf (⌥⌘S): the selection (or the folder shown) goes on the shelf, which opens if hidden.
    @objc func addToShelf(_ sender: Any?) {
        let store = ShelfStore.shared
        let added = store.add(actionTargets)
        if !showShelf { animatePanel(.sidebar, show: true) { self.showShelf = true } }
        view.statusBar.showMessage(
            added == 0
                ? "Already on the shelf."
                : "Added \(added) \(added == 1 ? "item" : "items") to “\(store.current.name)”.")
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

    /// Download: iCloud Drive items download now; account items stay on this Mac until Remove Download.
    @objc func cloudDownload(_ sender: Any?) {
        let c = view
        KeepDownloadedSheet.download(
            c.model.selectedItems, window: window,
            status: { text in if let text { c.statusBar.showMessage(text) } else { c.updateStatus() } },
            failed: { c.messageBar.show($0, error: true) })
    }

    @objc func cloudEvict(_ sender: Any?) {
        let urls = selectedURLs
        let failed = CloudCommands.removeDownload(urls)
        guard !failed.isEmpty else { return }
        // Accounts: a calm line says what stayed (unsent edits…); iCloud keeps its sheet.
        if !urls.allSatisfy(\.isFileURL) {
            view.messageBar.show(failed.prefix(3).joined(separator: " "), error: false)
            return
        }
        let a = NSAlert()
        a.messageText = "Some downloads could not be removed."
        a.informativeText = failed.prefix(6).joined(separator: "\n")
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Zips the selection next to it: "<name>.zip" for one item, "Archive.zip" for several.
    @objc func compress(_ sender: Any?) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let folder = Self.commonFolder(of: urls)
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let zipName = LocationOperations(for: folder).uniqueName(base, ext: "zip", in: folder)
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
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }  // name.tar.gz
        if base.isEmpty { base = "Archive" }
        let name = LocationOperations(for: parent).uniqueName(base, in: parent)
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
    static func commonFolder(of urls: [URL]) -> URL { PathMath.commonFolder(of: urls) }

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
}

extension MainWindowController {
    /// How the window reads an item's cloud state (tests give scratch files iCloud states).
    static var cloudState: (DirectoryModel, FileItem) -> (state: CloudState, isCloud: Bool) = { $0.cloud(for: $1) }

    /// Whether File › Download and Remove Download are shown: in a connected account's folder, in an iCloud Drive or File
    /// Provider folder (local file URLs, so `PlacesModel.isCloud` is false there), or for a selection they apply to. Only
    /// the folder and the selection are read (one cached lookup each), never every listed item.
    var offersCloudCommands: Bool {
        let model = view.model
        if PlacesModel.isCloud(view.url) { return true }
        let state = { Self.cloudState(model, $0) }
        if view.url.isFileURL, state(FileItem(url: view.url, name: view.url.lastPathComponent, isDirectory: true)).isCloud { return true }
        return !CloudCommands.available(for: model.selectedItems, cloud: state).isEmpty
    }

    /// Download and Remove Download in the File menu (the context menu builds its own): enabled as the selection
    /// allows, "Download Now" for iCloud Drive as in Finder.
    func validateCloud(_ item: NSMenuItem) -> Bool {
        let model = view.model
        let a = CloudCommands.available(for: model.selectedItems) { Self.cloudState(model, $0) }
        // Disabled items say why (the context menu's own tooltips stay otherwise).
        switch item.action {
        case #selector(cloudDownload(_:)):
            item.title = a.downloadTitle
            if !a.downloadEnabled { item.toolTip = a.reason }
            return a.download && a.downloadEnabled
        case #selector(cloudEvict(_:)):
            if !a.removeEnabled { item.toolTip = a.reason }
            return a.removeDownload && a.removeEnabled
        default: return false
        }
    }
}
