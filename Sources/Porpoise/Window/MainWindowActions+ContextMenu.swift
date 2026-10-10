import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Context menus (DolphinContextMenu)

extension MainWindowController {

    /// The user's own Trash folder (Dolphin's trash:/).
    static var userTrashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    /// Extensions offered "Extract Here" (what ditto/bsdtar can unpack).
    static let extractableExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z"]

    func contextMenu(for item: FileItem?, in c: ViewContainer) -> NSMenu {
        // The entries act on the active view: right-clicking the inactive split pane activates it first.
        if c !== view { containerDidBecomeActive(c) }
        let m = buildContextMenu(for: item, in: c)
        applyContextMenuSettings(m, hasItem: item != nil)
        return m
    }

    /// Settings › Context Menu: hide switched-off entries, add Copy To / Move To, show Delete next to Trash.
    private func applyContextMenuSettings(_ m: NSMenu, hasItem: Bool) {
        let s = Settings.shared
        let titles: [ContextMenuEntry: [String]] = [
            .addToPlaces: ["Add to Places"], .copyLocation: ["Copy Location"], .duplicate: ["Duplicate Here"],
            .openInNewTab: ["Open in New Tab", "Open in New Tabs", "Open Path in New Tab"], .openInNewWindow: ["Open in New Window"],
            .openInSplit: ["Open in Split View"], .openTerminal: ["Open Terminal Here"], .otherView: ["Copy to Other View", "Move to Other View"],
            .sortBy: ["Sort By"], .viewMode: ["View Mode"], .compress: ["Compress", "Extract Here"], .tags: ["Tags"],
            .share: ["Share…"], .quickLook: ["Quick Look"], .revealInFinder: ["Reveal in Finder"],
        ]
        for (entry, names) in titles where !s.contextMenuShows(entry) {
            for it in m.items where names.contains(it.title) { m.removeItem(it) }
        }
        if s.contextMenuShows(.deleteAlongsideTrash), let del = m.items.first(where: { $0.title == "Delete" && $0.isAlternate }) {
            del.isAlternate = false
            del.keyEquivalentModifierMask = []
        }
        if hasItem, s.contextMenuShows(.copyMoveTo), let idx = m.items.firstIndex(where: { $0.title == "Move to Trash" }) {
            m.insertItem(sub("Copy To", "edit-copy", destinationMenu(move: false)), at: max(0, idx - 1))
            m.insertItem(sub("Move To", "edit-move", destinationMenu(move: true)), at: max(0, idx))
        }
        // Tidy separators left behind.
        var lastWasSep = true
        for it in m.items {
            if it.isSeparatorItem { if lastWasSep { m.removeItem(it) } else { lastWasSep = true } } else { lastWasSep = false }
        }
        if let last = m.items.last, last.isSeparatorItem { m.removeItem(last) }
    }

    /// Dolphin's "Copy To / Move To" targets: places, recent folders, the other view, or a chosen folder.
    private func destinationMenu(move: Bool) -> NSMenu {
        let m = NSMenu()
        var seen = Set<String>()
        func add(_ title: String, _ url: URL, _ icon: String) {
            guard url.isFileURL, !seen.contains(url.path) else { return }
            seen.insert(url.path)
            m.addItem(item(title, icon, #selector(copyOrMoveTo(_:)), tag: move ? 1 : 0, obj: url))
        }
        if let other = tab.inactive { add("Other View (\(other.url.lastPathComponent))", other.url, "view-split-left-right") }
        for e in PlacesModel.shared.allEntries where !e.hidden && e.url.isFileURL && e.icon != "user-trash" { add(e.title, e.url, e.icon) }
        let recent = RecentLocations.shared.urls.prefix(6)
        if !recent.isEmpty { m.addItem(.separator()) }
        for u in recent { add(u.lastPathComponent, u, IconTheme.folderIconName(u)) }
        m.addItem(.separator())
        m.addItem(item("Browse…", "document-open-folder", #selector(copyOrMoveTo(_:)), tag: move ? 1 : 0))
        return m
    }

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
        let inTrash = c.url.isFileURL && c.url.standardizedFileURL == Self.userTrashURL.standardizedFileURL
        let sel = c.model.selectedItems
        guard let item else {
            // Empty area
            if inTrash {
                m.addItem(sub("Sort By", "view-sort", sortMenu()))
                m.addItem(sub("View Mode", "view-list-icons", Self.viewModeMenu()))
                m.addItem(.separator())
                m.addItem(self.item("Empty Trash", "trash-empty", #selector(emptyTrash(_:))))
                return m
            }
            m.addItem(sub("Create New", "list-add", Self.createNewMenu()))
            m.addItem(.separator())
            m.addItem(self.item(FileOperationsController.shared.pasteTitle, "edit-paste", #selector(paste(_:))))
            m.addItem(self.item("Add to Places", "bookmark-new", #selector(addToPlaces(_:))))
            m.addItem(.separator())
            m.addItem(sub("Sort By", "view-sort", sortMenu()))
            m.addItem(sub("View Mode", "view-list-icons", Self.viewModeMenu()))
            m.addItem(.separator())
            m.addItem(self.item("Open Terminal Here", "utilities-terminal", #selector(openTerminalHere(_:))))
            m.addItem(self.item("Reveal in Finder", "system-file-manager", #selector(revealInFinder(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Properties", "document-properties", #selector(properties(_:))))
            return m
        }
        if inTrash {
            m.addItem(self.item("Restore to Former Location", "restoration", #selector(restoreFromTrash(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Cut", "edit-cut", #selector(cut(_:))))
            m.addItem(self.item("Copy", "edit-copy", #selector(copy(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Delete", "edit-delete", #selector(deleteItem(_:))))
            m.addItem(.separator())
            m.addItem(self.item("Properties", "document-properties", #selector(properties(_:))))
            return m
        }
        let single = sel.count <= 1
        let local = item.url.isFileURL
        if single && item.isBrowsableFolder {
            m.addItem(self.item("Open in New Tab", "tab-new", #selector(ctxOpenInNewTab(_:)), obj: item.url))
            m.addItem(self.item("Open in New Window", "window-new", #selector(ctxOpenInNewWindow(_:)), obj: item.url))
            m.addItem(self.item("Open in Split View", "view-split-left-right", #selector(ctxOpenInSplit(_:)), obj: item.url))
            m.addItem(.separator())
        } else if !single && sel.allSatisfy(\.isBrowsableFolder) {
            m.addItem(self.item("Open in New Tabs", "tab-new", #selector(ctxOpenInNewTabs(_:))))
            m.addItem(.separator())
        }
        if c.model.isSearching || c.model.isVirtual {
            m.addItem(self.item("Open Path", "document-open-folder", #selector(ctxOpenPath(_:)), obj: item.url))
            m.addItem(self.item("Open Path in New Tab", "tab-new", #selector(ctxOpenPathTab(_:)), obj: item.url))
            m.addItem(.separator())
        }
        // Launch Services only knows local files; remote items open through RemoteOpener (double-click).
        if local { addOpenWith(to: m, item: item) }
        addCloudItems(to: m, selection: sel, in: c)
        if item.isSymlink || Self.isAlias(item) { m.addItem(self.item("Show Original", "document-open-folder", #selector(showOriginal(_:)))) }
        if single && item.isPackage { m.addItem(self.item("Show Package Contents", "folder-open", #selector(showPackageContents(_:)))) }
        if single && item.isBrowsableFolder {
            m.addItem(sub("Create New", "list-add", Self.createNewMenu()))
        }
        m.addItem(.separator())
        m.addItem(self.item("Cut", "edit-cut", #selector(cut(_:))))
        m.addItem(self.item("Copy", "edit-copy", #selector(copy(_:))))
        m.addItem(self.item("Copy Location", "edit-copy-path", #selector(copyLocation(_:))))
        if single && item.isBrowsableFolder {
            m.addItem(self.item("Paste Into Folder", "edit-paste", #selector(paste(_:)), obj: Self.pasteIntoFolder))
        }
        m.addItem(self.item("Duplicate Here", "edit-duplicate", #selector(duplicateItem(_:))))
        m.addItem(self.item("Make Alias", "insert-link", #selector(makeAlias(_:))))
        m.addItem(self.item("Rename…", "edit-rename", #selector(renameItem(_:))))
        if !single { m.addItem(self.item("New Folder with Selection (\(sel.count) Items)", "folder-new", #selector(newFolderWithSelection(_:)))) }
        if single && item.isBrowsableFolder && !PlacesModel.shared.contains(item.url) {
            m.addItem(self.item("Add to Places", "bookmark-new", #selector(addToPlaces(_:))))
        }
        m.addItem(.separator())
        m.addItem(self.item("Move to Trash", "user-trash", #selector(moveToTrash(_:))))
        // ⇧ turns Move to Trash into Delete (Settings › Context Menu can show it permanently).
        let del = self.item("Delete", "edit-delete", #selector(deleteItem(_:)), mods: .shift)
        del.isAlternate = true
        m.addItem(del)
        m.addItem(.separator())
        if single && item.isBrowsableFolder {
            m.addItem(self.item("Open Terminal Here", "utilities-terminal", #selector(openTerminalHere(_:))))
        }
        m.addItem(self.item("Compress", "archive-insert", #selector(compress(_:))))
        if Self.extractableExtensions.contains(item.fileExtension.lowercased()) {
            m.addItem(self.item("Extract Here", "archive-extract", #selector(extractHere(_:))))
        }
        if single, local, item.utType?.conforms(to: .image) == true {
            m.addItem(self.item("Set Desktop Picture", "preferences-desktop-wallpaper", #selector(setDesktopPicture(_:))))
        }
        m.addItem(.separator())
        // Finder tags live in extended attributes: local items only.
        if sel.allSatisfy({ $0.url.isFileURL }) {
            m.addItem(TagDotsView.menuItem(for: sel) { [weak self] tag in self?.toggleTag(tag) })
            m.addItem(sub("Tags", "tag", tagsMenu(for: sel)))
        }
        m.addItem(self.item("Share…", "document-share", #selector(shareItems(_:))))
        m.addItem(self.item("Quick Look", "document-preview", #selector(quickLook(_:))))
        m.addItem(self.item("Reveal in Finder", "system-file-manager", #selector(revealInFinder(_:))))
        if tab.isSplit {
            m.addItem(.separator())
            m.addItem(self.item("Copy to Other View", "edit-copy", #selector(copyToOtherView(_:))))
            m.addItem(self.item("Move to Other View", "edit-move", #selector(moveToOtherView(_:))))
        }
        m.addItem(.separator())
        m.addItem(self.item("Properties", "document-properties", #selector(properties(_:))))
        return m
    }

    /// Cloud items (iCloud Drive, Google Drive…): Finder's Download Now / Remove Download, right under Open.
    private func addCloudItems(to m: NSMenu, selection sel: [FileItem], in c: ViewContainer) {
        let clouds = sel.map { c.model.cloud(for: $0) }
        guard clouds.contains(where: { $0.isCloud }) else { return }
        if clouds.contains(where: { $0.state == .cloudOnly }) || sel.contains(where: \.isBrowsableFolder) {
            let it = item("Download Now", nil, #selector(cloudDownload(_:)))
            it.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
            m.addItem(it)
        }
        if clouds.contains(where: { $0.isCloud && $0.state != .cloudOnly }) {
            let it = item("Remove Download", nil, #selector(cloudEvict(_:)))
            it.image = NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: nil)
            it.toolTip = "Free up space on this Mac. The item stays in the cloud."
            m.addItem(it)
        }
        m.addItem(.separator())
    }

    /// Folders get an "Open With" list of apps; files get "Open with <default>" plus the list.
    private func addOpenWith(to m: NSMenu, item: FileItem) {
        let ws = NSWorkspace.shared
        if item.isBrowsableFolder && !item.isApplication {
            let apps = ws.urlsForApplications(toOpen: item.url).filter { $0.lastPathComponent != "Finder.app" }.prefix(12)
            guard !apps.isEmpty else { return }
            let sm = NSMenu()
            for a in apps { sm.addItem(openWithItem(a)) }
            m.addItem(sub("Open With", "document-open", sm))
            return
        }
        let def = ws.urlForApplication(toOpen: item.url)
        if let d = def {
            let it = openWithItem(d)
            it.title = "Open with \(Self.appName(d))"
            m.addItem(it)
        }
        let others = ws.urlsForApplications(toOpen: item.url).filter { $0 != def }.prefix(15)
        let sm = NSMenu()
        for a in others { sm.addItem(openWithItem(a)) }
        if !others.isEmpty { sm.addItem(.separator()) }
        sm.addItem(self.item("Other Application…", nil, #selector(ctxOpenWithOther(_:))))
        m.addItem(sub("Open With", "document-open", sm))
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func openWithItem(_ app: URL) -> NSMenuItem {
        let it = NSMenuItem(title: Self.appName(app), action: #selector(ctxOpenWith(_:)), keyEquivalent: "")
        it.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        it.image = icon
        return it
    }

    private func tagsMenu(for items: [FileItem]) -> NSMenu {
        let m = NSMenu()
        let colors: [(String, NSColor)] = [("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
                                           ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray)]
        let current = Set(items.flatMap { Self.tagNames(of: $0.url) })
        for (name, color) in colors {
            let it = self.item(name, nil, #selector(setTag(_:)), obj: name)
            it.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            it.state = current.contains(name) ? .on : .off
            m.addItem(it)
        }
        return m
    }

    // MARK: Context menu actions

    @objc func ctxOpenInNewTab(_ s: NSMenuItem) { if let u = s.representedObject as? URL { addTab(url: u, select: false) } }
    @objc func ctxOpenInNewTabs(_ s: NSMenuItem) { for it in view.model.selectedItems where it.isBrowsableFolder { addTab(url: it.url, select: false) } }
    @objc func ctxOpenInNewWindow(_ s: NSMenuItem) { if let u = s.representedObject as? URL { AppDelegate.shared.newWindow(at: u) } }

    @objc func ctxOpenInSplit(_ s: NSMenuItem) {
        guard let u = s.representedObject as? URL else { return }
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
        NSWorkspace.shared.open(selectedURLs.filter(\.isFileURL), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func ctxOpenWithOther(_ s: NSMenuItem) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        p.message = "Choose an application to open the selected items"
        runPanel(p) { app in NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
    }
}
