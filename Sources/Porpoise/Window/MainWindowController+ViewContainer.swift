import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import Quartz

// MARK: - ViewContainerDelegate

extension MainWindowController {
    func containerDidBecomeActive(_ c: ViewContainer) {
        guard tabs.indices.contains(current) else { return }
        if tab.secondary === c && !tab.activeIsSecondary {
            tab.setActive(secondary: true); syncToActiveView()
        } else if tab.primary === c && tab.activeIsSecondary {
            tab.setActive(secondary: false); syncToActiveView()
        }
        AppDelegate.shared.sessionChanged()
    }

    func containerDidChangeURL(_ c: ViewContainer) {
        if c === view { driveMediaQuickLook?.close() }
        linkedNavigationChanged(c)
        AppDelegate.shared.sessionChanged()
        if c === view || tab.containers.contains(where: { $0 === c }) {
            syncToActiveView()
        } else if allContainers.contains(where: { $0 === c }) {
            updateTabBar()
        }  // a background tab's title
    }

    func containerAirDropPeer(_ c: ViewContainer) -> ViewContainer? {
        tabs.first(where: { $0.containers.contains(where: { $0 === c }) })?.containers.first(where: { $0 !== c })
    }
    func container(_ c: ViewContainer, shareWithAirDrop urls: [URL], from anchor: NSView) {
        SharingCoordinator.shared.share(urls, mode: .airDrop, from: anchor)
    }
    func containerSelectionChanged(_ c: ViewContainer) {
        guard tabs.indices.contains(current) else { return }
        for pane in tab.containers where pane.showsAirDrop { pane.refreshAirDropSelection() }
        if c === view {
            if showInformation { information.show(hovered: nil, container: c) }
            refreshQuickLook()
        }
    }

    func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) {
        // Finder aliases open their original (a folder alias browses into it).
        let items = items.map { it -> FileItem in
            guard Self.isAlias(it), let t = Self.resolvedTarget(of: it), let r = FileItem.load(t) else { return it }
            return r
        }
        // Finder Smart Folders open as live Spotlight results.
        if items.count == 1, items[0].url.pathExtension == "savedSearch",
            let u = URL(string: "smart://" + (items[0].url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
        {
            if inNewTab { addTab(url: u) } else { c.setURL(u) }
            return
        }
        // Local archives list without extraction; uncommon formats use the safe whole-archive fallback.
        if Settings.shared.browseArchives, items.count == 1, items[0].url.isFileURL, ArchiveBrowser.isArchive(items[0]) {
            let archive = items[0]
            if let location = ArchiveBrowser.location(for: archive) {
                if inNewTab { addTab(url: location); return }
                c.setURL(location)
                c.messageBar.show("Browsing “\(archive.name)”. Archives are read-only; files are extracted when opened or copied.", error: false)
                c.needsLayout = true
                return
            }
            if inNewTab { openFiles(items); return }  // Preserve the existing fallback for uncommon formats.
            c.statusBar.showMessage("Opening “\(archive.name)”…")
            let asked = c.navigations
            ArchiveBrowser.extractedFolder(for: archive) { [weak c] result in
                if let c { Self.extracted(result, archive: archive.name, in: c, asked: asked) }
            }
            return
        }
        let folders = items.filter(\.isBrowsableFolder)
        let files = items.filter { !$0.isBrowsableFolder }
        if folders.count + files.count > 10 && Settings.shared.confirmOpenMany {
            let a = NSAlert()
            a.messageText = "Are you sure you want to open \(items.count) items?"
            a.addButton(withTitle: "Open")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if folders.count == 1 && files.isEmpty && !inNewTab {
            c.setURL(folders[0].url)
        } else {
            for f in folders { addTab(url: f.url, select: false) }
        }
        if !files.isEmpty { openFiles(files) }
    }

    func openFiles(_ items: [FileItem]) {
        for it in items {
            if isExecutable(it) {
                // Settings › Confirmations › "When opening an executable file".
                switch Settings.shared.executableAction {
                case .run: ExternalTerminal.run(it.url); continue
                case .open: NSWorkspace.shared.open(it.url); continue
                case .ask:
                    let a = NSAlert()
                    a.messageText = "“\(it.name)” is an executable file. Do you want to run it, or open it in an application?"
                    a.addButton(withTitle: "Run")
                    a.addButton(withTitle: "Open")
                    a.addButton(withTitle: "Cancel")
                    switch a.runModal() {
                    case .alertFirstButtonReturn: ExternalTerminal.run(it.url)
                    case .alertSecondButtonReturn: NSWorkspace.shared.open(it.url)
                    default: break
                    }
                    continue
                }
            }
            if AccountActions.openWebDocument(it.url) { continue }
            if !it.url.isFileURL { RemoteOpener.open(it); continue }
            NSWorkspace.shared.open(it.url)
        }
    }

    /// Scripts and binaries with the executable bit (not apps/bundles).
    private func isExecutable(_ it: FileItem) -> Bool {
        guard it.url.isFileURL, !it.isDirectory, it.posixPermissions & 0o111 != 0, let t = it.utType else { return false }
        return t.conforms(to: .shellScript) || t.conforms(to: .unixExecutable) || t.conforms(to: .script)
    }

    func container(_ c: ViewContainer, menuFor item: FileItem?) -> NSMenu? { contextMenu(for: item, in: c) }

    func container(_ c: ViewContainer, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {
        FileOperationsController.shared.handleDrop(urls, onto: folder, operation: operation, in: c.list)
    }

    func container(_ c: ViewContainer, rename item: FileItem, to name: String) { rename(item, to: name, in: c) }

    func container(_ c: ViewContainer, middleClicked item: FileItem) {
        if item.isBrowsableFolder {
            addTab(url: item.url, select: false)
        } else if AccountActions.openWebDocument(item.url) {
            return
        } else if !item.url.isFileURL {
            RemoteOpener.open(item)
        } else {
            // Dolphin opens files with the second associated app on middle-click.
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            if apps.count > 1 {
                NSWorkspace.shared.open([item.url], withApplicationAt: apps[1], configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    /// Moves every view that shows something on `volume` to the home folder, so the volume can be ejected.
    /// An archive's contents were extracted for pane `c`, sent somewhere `asked` times then: it goes there, unless it
    /// was sent elsewhere meanwhile; then it stays, and can open the contents from its message bar.
    static func extracted(_ result: Result<URL, Error>, archive: String, in c: ViewContainer, asked: Int) {
        guard c.navigations == asked else {
            if case .success(let dir) = result {
                c.messageBar.show("The contents of “\(archive)” are ready.", error: false, action: "Open") { [weak c] in c?.setURL(dir) }
                c.needsLayout = true
            }
            return
        }
        switch result {
        case .success(let dir):
            c.setURL(dir)
            c.messageBar.show("Browsing the contents of “\(archive)”. This is a read-only copy; changes are not saved to the archive.", error: false)
        case .failure(let e): c.messageBar.show(e.localizedDescription, error: true)
        }
        c.needsLayout = true
    }

    /// Sends every pane showing `volume` home. Returns how to put them back where they were if the eject fails.
    @discardableResult
    static func leaveVolume(_ volume: URL) -> VolumeLeave {
        let root = volume.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let home = FileManager.default.homeDirectoryForCurrentUser
        var left = VolumeLeave()
        for w in AppDelegate.shared.windows {
            for t in w.tabs {
                for c in [t.primary, t.secondary].compactMap({ $0 }) where c.url.isFileURL {
                    let p = c.url.standardizedFileURL.path
                    guard p == root || p.hasPrefix(prefix) else { continue }
                    let was = c.url
                    c.setURL(home)
                    left.panes.append((VolumeLeave.Weak(c), was, c.navigations))
                }
            }
        }
        return left
    }

    func containerQuickLook(_ c: ViewContainer) { quickLook(nil) }
    func containerSearchVisibilityChanged(_ c: ViewContainer) { if c === view { toolbar.search.isToggled = !c.searchBar.isHidden } }

    func rename(_ item: FileItem, to name: String, in c: ViewContainer) {
        let old = item.url
        if PlacesModel.isCloud(old) { renameCloud(item, to: name, in: c); return }
        let newExt = (name as NSString).pathExtension
        if Settings.shared.confirmRenameType, !item.isBrowsableFolder, newExt.lowercased() != item.fileExtension.lowercased(),
            !item.fileExtension.isEmpty
        {
            let a = NSAlert()
            a.messageText = "Change File Type"
            a.informativeText = "Changing the file extension from “\(item.fileExtension)” to “\(newExt)” may change the way the file opens."
            a.addButton(withTitle: "Change Type")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if Settings.shared.confirmRenameHide, name.hasPrefix(".") && !item.name.hasPrefix(".") && !c.model.props.showHidden {
            let a = NSAlert()
            a.messageText = "Hide this File?"
            a.informativeText = "The name starts with a dot, so the item will be hidden."
            a.addButton(withTitle: "Rename and Hide")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if !old.isFileURL {
            // A server: the name is checked against its folder and the rename can be undone, as on this Mac.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try LocationOperations(for: old).rename(old, to: name) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let renamed):
                        if let undo = renamed.undo { FileOperationsController.shared.pushUndo(undo) }
                        c.pendingSelect = renamed.url; c.reload()
                    case .failure(let error):
                        c.messageBar.show(error.localizedDescription, error: true); c.needsLayout = true
                    }
                }
            }
            return
        }
        do {
            let renamed = try LocationOperations(for: old).rename(old, to: name)
            if let undo = renamed.undo { FileOperationsController.shared.pushUndo(undo) }
            c.pendingSelect = renamed.url
            c.reload()
        } catch  where FileErrorKind.classify(error) == .permission {
            // Root-owned item or folder: authenticate, as Finder does.
            let new = old.deletingLastPathComponent().appendingPathComponent(name)
            if FileOperationsController.shared.authorize(
                verb: "rename", items: [old],
                commands: FileOperationsController.renameCommands(old, to: new), window: window)
            {
                FileOperationsController.shared.pushUndo(.renamed(from: old, to: new))
                c.pendingSelect = new
            }
            c.reload()
        } catch {
            let a = NSAlert(error: error)
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
        }
    }
}

/// The panes an eject sent home, and where they were.
struct VolumeLeave {
    struct Weak { weak var pane: ViewContainer?; init(_ p: ViewContainer) { pane = p } }
    var panes: [(pane: Weak, url: URL, navigations: Int)] = []

    /// The eject failed: each pane still at home (not sent anywhere since) goes back.
    @MainActor func putBack() {
        for (w, url, n) in panes {
            if let c = w.pane, c.navigations == n { c.setURL(url) }
        }
    }
}
