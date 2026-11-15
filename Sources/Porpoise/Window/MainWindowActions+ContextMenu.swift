import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Context menus (DolphinContextMenu)

extension MainWindowController {

    /// Extensions offered "Extract Here" (what ditto/bsdtar can unpack).
    static let extractableExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z"]

    func contextMenu(for item: FileItem?, in c: ViewContainer) -> NSMenu {
        // The entries act on the active view: right-clicking the inactive split pane activates it first.
        if c !== view { containerDidBecomeActive(c) }
        let m = buildContextMenu(for: item, in: c)
        if let actions = quickActionMenu(for: item, in: c) { m.addItem(.separator()); m.addItem(sub("Quick Actions", "system-run", actions)) }
        let tools = customToolMenu(.contextMenu)
        if !tools.items.isEmpty { m.addItem(.separator()); m.addItem(sub("Custom Tools", "system-run", tools)) }
        FileContextMenu.applySettings(m, hasItem: item != nil) { self.destinationMenu(move: $0) }
        MenuCommandRegistry.shared.apply(to: m)
        return m
    }

    /// The toolbar's Action (⋯) button, as in Finder: the selection's context menu (the folder's without one), under it.
    func showActionMenu(from button: NSView) {
        Self.popUpActionMenu(contextMenu(for: view.model.selectedItems.first, in: view), button)
    }

    /// Opens the Action menu under its button (tests record it instead: a real pop-up tracks the mouse until closed).
    static var popUpActionMenu: (NSMenu, NSView) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    private func destinationMenu(move: Bool) -> NSMenu { FileContextMenu.destinationMenu(other: tab.inactive?.url, move: move) }

    /// Copy To / Move To: tag 1 moves; no target URL means "Browse…".
    @objc func copyOrMoveTo(_ sender: NSMenuItem) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let kind: FileOperationKind = sender.tag == 1 ? .move : .copy
        if let dest = sender.representedObject as? URL {
            FileOperationsController.shared.run(kind, urls, to: dest, window: window)
            return
        }
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = kind == .move ? "Move Here" : "Copy Here"
        runPanel(p) { [weak self] dest in FileOperationsController.shared.run(kind, urls, to: dest, window: self?.window) }
    }

    /// Open/save panels as a sheet on this window.
    func runPanel(_ p: NSOpenPanel, _ done: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { r in if r == .OK, let u = p.url { done(u) } }
        if let w = window { p.beginSheetModal(for: w, completionHandler: finish) } else { finish(p.runModal()) }
    }

    private func buildContextMenu(for item: FileItem?, in c: ViewContainer) -> NSMenu {
        let m = NSMenu()
        let inTrash = c.model.kind == .trash
        let sel = c.model.selectedItems
        if PlacesModel.isCloud(c.url) { return cloudContextMenu(for: item, selection: sel, in: c) }
        guard let item else {
            // Empty area
            if inTrash {
                m.addItem(sub("Sort By", "view-sort", sortMenu()))
                m.addItem(sub("View Mode", "view-list-icons", Self.viewModeMenu()))
                m.addItem(.separator())
                m.addItem(self.item("Empty Trash", "trash-empty", #selector(emptyTrash(_:))))
                return m
            }
            return FileContextMenu.background(sort: sortMenu(), group: groupMenu(), viewModes: Self.viewModeMenu())
        }
        if inTrash {
            m.addItem(self.item("Restore to Former Location", "restoration", #selector(restoreFromTrash(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Cut", "edit-cut", #selector(cut(_:))))
            m.addItem(self.item("Copy", "edit-copy", #selector(copy(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Delete", "edit-delete", #selector(deleteItem(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Get Info", "document-properties", #selector(properties(_:))))
            return m
        }
        return FileContextMenu.file(
            item, model: c.model,
            hasOtherView: tab.isSplit, canCompareFiles: fileComparisonSelection.count == 2,
            cloudItems: { self.addCloudItems(to: $0, selection: sel, in: c) },
            gitItems: { self.addGitChanges(to: $0, item: $1, in: c, single: $2) }, tags: { self.tagsMenu(for: $0) },
            tagToggle: { [weak self] in self?.toggleTag($0) })
    }

    /// Google Drive: the local menu's editing commands, each disabled with the reason when the item's sharing doesn't
    /// allow it, plus opening in the browser, Add to Places and links.
    private func cloudContextMenu(for item: FileItem?, selection sel: [FileItem], in c: ViewContainer) -> NSMenu {
        let m = NSMenu()
        let single = sel.count <= 1
        guard let item else {
            m.addItem(self.item("New Folder…", "folder-new", #selector(createFolder(_:))))
            m.addItem(.separator())
            m.addItem(self.item(FileOperationsController.shared.pasteTitle, "edit-paste", #selector(paste(_:))))
            if c.url.pathComponents.count > 2, !PlacesModel.shared.contains(c.url) {
                m.addItem(self.item("Add to Places", "bookmark-new", #selector(addToPlaces(_:))))
            }
            if CloudAccounts.shared.info(for: c.url)?.webLink != nil {
                m.addItem(self.item("Open in Browser", "internet-web-browser", #selector(openInBrowser(_:)), obj: c.url))
            }
            m.addItem(.separator())
            m.addItem(sub("Sort By", "view-sort", sortMenu()))
            m.addItem(sub("View Mode", "view-list-icons", Self.viewModeMenu()))
            m.addItem(.separator())
            m.addItem(self.item("Get Info", "document-properties", #selector(properties(_:))))
            return m
        }
        if single && item.isBrowsableFolder {
            m.addItem(self.item("Open in New Tab", "tab-new", #selector(ctxOpenInNewTab(_:)), obj: item.url))
            m.addItem(self.item("Open in New Window", "window-new", #selector(ctxOpenInNewWindow(_:)), obj: item.url))
            m.addItem(self.item("Open in Split View", "view-split-left-right", #selector(ctxOpenInSplit(_:)), obj: item.url))
            m.addItem(.separator())
        }
        let info = single ? CloudAccounts.shared.info(for: item.url) : nil
        if info?.webLink != nil {
            m.addItem(self.item("Open in Browser", "internet-web-browser", #selector(openInBrowser(_:)), obj: item.url))
        }
        if single && item.isBrowsableFolder && !PlacesModel.shared.contains(item.url) {
            m.addItem(self.item("Add to Places", "bookmark-new", #selector(addToPlaces(_:))))
        }
        m.addItem(.separator())
        addCloudItems(to: m, selection: sel, in: c)
        m.addItem(self.item("Cut", "edit-cut", #selector(cut(_:))))
        m.addItem(self.item("Copy", "edit-copy", #selector(copy(_:))))
        if info?.webLink != nil { m.addItem(self.item("Copy Link", "link", #selector(copyCloudLink(_:)), obj: item.url)) }
        if single && item.isBrowsableFolder {
            m.addItem(self.item("Paste Into Folder", "edit-paste", #selector(paste(_:)), obj: Self.pasteIntoFolder))
        }
        m.addItem(self.item("Rename…", "edit-rename", #selector(renameItem(_:))))
        m.addItem(.separator())
        m.addItem(self.item(CloudAccounts.shared.deletionTitle(for: item.url), "user-trash", #selector(moveToTrash(_:))))
        m.addItem(.separator())
        m.addItem(self.item("Quick Look", "document-preview", #selector(quickLook(_:))))
        m.addItem(self.item("Get Info", "document-properties", #selector(properties(_:))))
        return m
    }

    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let link = CloudAccounts.shared.info(for: u)?.webLink else { return }
        NSWorkspace.shared.open(AccountActions.webLink(link, account: CloudAccounts.shared.account(for: u)))
    }

    @objc func copyCloudLink(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let link = CloudAccounts.shared.info(for: u)?.webLink else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([link as NSURL])
        pb.setString(link.absoluteString, forType: .string)
    }

    /// Cloud items (iCloud Drive, Google Drive…): Finder's Download Now / Keep Downloaded / Remove Download, right
    /// under Open.
    private func addCloudItems(to m: NSMenu, selection sel: [FileItem], in c: ViewContainer) {
        let a = CloudCommands.available(for: sel) { c.model.cloud(for: $0) }
        guard !a.isEmpty else { return }
        if a.download {
            let it = item(a.downloadTitle, nil, #selector(cloudDownload(_:)))
            it.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
            it.toolTip = !a.downloadEnabled ? a.reason : a.downloadTitle == "Download" ? "Keep a copy on this Mac, updated when it changes." : nil
            m.addItem(it)
        }
        if a.removeDownload {
            let it = item("Remove Download", nil, #selector(cloudEvict(_:)))
            it.image = NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: nil)
            it.toolTip = a.removeEnabled ? "Free up space on this Mac. The item stays in the cloud." : a.reason
            m.addItem(it)
        }
        m.addItem(.separator())
    }

    static func appName(_ app: URL) -> String { FileContextMenu.appName(app) }

    func tagsMenu(for items: [FileItem]) -> NSMenu { FileContextMenu.tagsMenu(for: items) }

    // MARK: Context menu actions

    /// The one selected folder, for the context menu's Open in… items when they come from the menu bar or the palette.
    var selectedFolder: URL? {
        let selected = view.model.selectedItems
        return selected.count == 1 && selected[0].isBrowsableFolder ? selected[0].url : nil
    }
    private func folder(_ s: NSMenuItem) -> URL? { s.representedObject as? URL ?? selectedFolder }

    @objc func ctxOpenInNewTab(_ s: NSMenuItem) { if let u = folder(s) { addTab(url: u, select: false) } }
    @objc func ctxOpenInNewTabs(_ s: NSMenuItem) {
        for it in view.model.selectedItems where it.isBrowsableFolder { addTab(url: it.url, select: false) }
    }
    @objc func ctxOpenInNewWindow(_ s: NSMenuItem) { if let u = folder(s) { AppDelegate.shared.newWindow(at: u) } }

    @objc func ctxOpenInSplit(_ s: NSMenuItem) {
        guard let u = folder(s) else { return }
        if tab.isSplit { tab.inactive?.setURL(u) } else { tab.openSplit(url: u); tab.secondary?.delegate = self }
        syncToActiveView()
    }

    @objc func ctxOpenPath(_ s: NSMenuItem) {
        guard let u = s.representedObject as? URL else { return }
        view.setURL(u.deletingLastPathComponent(), selecting: u)
    }

    @objc func ctxOpenPathTab(_ s: NSMenuItem) {
        guard let u = s.representedObject as? URL else { return }
        addTab(url: u.deletingLastPathComponent())
    }

    @objc func ctxOpenWith(_ s: NSMenuItem) {
        guard let app = s.representedObject as? URL else { return }
        openSelection(with: app)
    }

    private func openSelection(with app: URL, urls: [URL]? = nil, remote: [FileItem]? = nil) {
        let local = (urls ?? selectedURLs).filter(\.isFileURL)
        if !local.isEmpty { NSWorkspace.shared.open(local, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        for item in remote ?? view.model.selectedItems where PlacesModel.isCloud(item.url) {
            RemoteOpener.open(item, using: { NSWorkspace.shared.open([$0], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) })
        }
    }

    @objc func ctxOpenWithOther(_ s: NSMenuItem) {
        let urls = selectedURLs
        let remote = view.model.selectedItems
        guard !urls.isEmpty else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        p.message = "Choose an application to open the selected items"
        runPanel(p) { [weak self] app in self?.openSelection(with: app, urls: urls, remote: remote) }
    }
}
