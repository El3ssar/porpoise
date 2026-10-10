import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

// MARK: - ViewContainerDelegate

extension MainWindowController {
    func containerDidBecomeActive(_ c: ViewContainer) {
        guard tabs.indices.contains(current) else { return }
        if tab.secondary === c && !tab.activeIsSecondary { tab.setActive(secondary: true); syncToActiveView() }
        else if tab.primary === c && tab.activeIsSecondary { tab.setActive(secondary: false); syncToActiveView() }
    }

    func containerDidChangeURL(_ c: ViewContainer) {
        if c === view || tab.containers.contains(where: { $0 === c }) { syncToActiveView() }
        else if allContainers.contains(where: { $0 === c }) { updateTabBar() }   // a background tab's title
    }

    func containerSelectionChanged(_ c: ViewContainer) {
        if c === view, showInformation { information.show(hovered: nil, container: c) }
        if c === view, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) {
        // Finder aliases open their original (a folder alias browses into it).
        let items = items.map { it -> FileItem in
            guard Self.isAlias(it), let t = Self.resolvedTarget(of: it), let r = FileItem.load(t) else { return it }
            return r
        }
        // Finder Smart Folders open as live Spotlight results.
        if items.count == 1, items[0].url.pathExtension == "savedSearch", let u = URL(string: "smart://" + (items[0].url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")) {
            if inNewTab { addTab(url: u) } else { c.setURL(u) }
            return
        }
        // "Browse compressed files as folders": open archives like folders (an extracted, read-only copy).
        if Settings.shared.browseArchives, items.count == 1, items[0].url.isFileURL, ArchiveBrowser.isArchive(items[0]), !inNewTab {
            let archive = items[0]
            c.statusBar.showMessage("Opening “\(archive.name)”…")
            ArchiveBrowser.extractedFolder(for: archive) { result in
                switch result {
                case .success(let dir):
                    c.setURL(dir)
                    c.messageBar.show("Browsing the contents of “\(archive.name)”. This is a read-only copy; changes are not saved to the archive.", error: false)
                    c.needsLayout = true
                case .failure(let e): c.messageBar.show(e.localizedDescription, error: true); c.needsLayout = true
                }
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
        if item.isBrowsableFolder { addTab(url: item.url, select: false) }
        else if !item.url.isFileURL { RemoteOpener.open(item) }
        else {
            // Dolphin opens files with the second associated app on middle-click.
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            if apps.count > 1 { NSWorkspace.shared.open([item.url], withApplicationAt: apps[1], configuration: NSWorkspace.OpenConfiguration()) }
            else { NSWorkspace.shared.open(item.url) }
        }
    }

    /// Moves every view that shows something on `volume` to the home folder, so the volume can be ejected.
    static func leaveVolume(_ volume: URL) {
        let root = volume.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let home = FileManager.default.homeDirectoryForCurrentUser
        for w in AppDelegate.shared.windows {
            for t in w.tabs {
                for c in [t.primary, t.secondary].compactMap({ $0 }) where c.url.isFileURL {
                    let p = c.url.standardizedFileURL.path
                    if p == root || p.hasPrefix(prefix) { c.setURL(home) }
                }
            }
        }
    }

    func containerQuickLook(_ c: ViewContainer) { quickLook(nil) }
    func containerSearchVisibilityChanged(_ c: ViewContainer) { if c === view { toolbar.search.isToggled = !c.searchBar.isHidden } }

    func rename(_ item: FileItem, to name: String, in c: ViewContainer) {
        let old = item.url
        if let p = RemoteFS.provider(for: old) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try p.rename(old, to: name)
                    DispatchQueue.main.async { c.pendingSelect = old.deletingLastPathComponent().appendingPathComponent(name); c.reload() }
                } catch {
                    DispatchQueue.main.async { c.messageBar.show(error.localizedDescription, error: true); c.needsLayout = true }
                }
            }
            return
        }
        let newExt = (name as NSString).pathExtension
        if Settings.shared.confirmRenameType, !item.isBrowsableFolder, newExt.lowercased() != item.fileExtension.lowercased(), !item.fileExtension.isEmpty {
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
        do {
            let new = try FileActions.rename(old, to: name)
            FileOperationsController.shared.pushUndo(.renamed(from: old, to: new))
            c.pendingSelect = new
            c.reload()
        } catch where FileJob.isPermissionError(error) {
            // Root-owned item or folder: authenticate, as Finder does.
            let new = old.deletingLastPathComponent().appendingPathComponent(name)
            if FileOperationsController.shared.authorize(verb: "rename", items: [old],
                                                  commands: FileOperationsController.renameCommands(old, to: new), window: window) {
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
