import AppKit
import PorpoiseCore
import PorpoiseServices

/// The browser and desktop share the actual local-file menu, including command identities and ordering.
/// Each surface supplies its own action target and omits commands that do not apply there.
enum FileContextMenu {
    static func command(
        _ title: String, _ icon: String?, _ action: Selector, key: String = "",
        mods: NSEvent.ModifierFlags = .command, tag: Int = 0, obj: Any? = nil
    ) -> NSMenuItem {
        .make(title, action, key: key, mods: mods, icon: icon, tag: tag, obj: obj)
    }
    static func sub(_ title: String, _ icon: String?, _ menu: NSMenu) -> NSMenuItem { .submenu(title, icon: icon, menu) }

    static func background(sort: NSMenu, group: NSMenu, viewModes: NSMenu) -> NSMenu {
        let m = NSMenu()
        // Finder's first entry: the thing most often done on empty space.
        m.addItem(command("New Folder…", "folder-new", #selector(MainWindowController.createFolder(_:)), key: "n", mods: [.command, .shift]))
        m.addItem(sub("Create New", "list-add", MainWindowController.createNewMenu(folder: false)))
        m.addItem(.separator())
        m.addItem(command(FileOperationsController.shared.pasteTitle, "edit-paste", #selector(MainWindowController.paste(_:))))
        m.addItem(command("Add to Places", "bookmark-new", #selector(MainWindowController.addToPlaces(_:))))
        m.addItem(.separator())
        m.addItem(sub("Sort By", "view-sort", sort))
        m.addItem(sub("Group By", "view-group", group))
        m.addItem(sub("View Mode", "view-list-icons", viewModes))
        m.addItem(command("Adjust View Display Style…", "configure", #selector(MainWindowController.adjustViewStyle(_:))))
        m.addItem(.separator())
        m.addItem(command("Open Terminal Here", "utilities-terminal", #selector(MainWindowController.openTerminalHere(_:))))
        m.addItem(.separator())
        m.addItem(command("Get Info", "document-properties", #selector(MainWindowController.properties(_:))))
        return m
    }

    static func file(
        _ item: FileItem, model: DirectoryModel,
        hasOtherView: Bool = false, canCompareFiles: Bool = false,
        cloudItems: (NSMenu) -> Void = { _ in }, gitItems: (NSMenu, FileItem, Bool) -> Void = { _, _, _ in },
        tags: ([FileItem]) -> NSMenu = { _ in NSMenu() }, tagToggle: ((String) -> Void)? = nil
    ) -> NSMenu {
        let m = NSMenu(), sel = model.selectedItems
        let single = sel.count <= 1
        let local = item.url.isFileURL
        if single && item.isBrowsableFolder {
            m.addItem(command("Open in New Tab", "tab-new", #selector(MainWindowController.ctxOpenInNewTab(_:)), obj: item.url))
            m.addItem(command("Open in New Window", "window-new", #selector(MainWindowController.ctxOpenInNewWindow(_:)), obj: item.url))
            m.addItem(command("Open in Split View", "view-split-left-right", #selector(MainWindowController.ctxOpenInSplit(_:)), obj: item.url))
            m.addItem(.separator())
        } else if !single && sel.allSatisfy(\.isBrowsableFolder) {
            m.addItem(command("Open in New Tabs", "tab-new", #selector(MainWindowController.ctxOpenInNewTabs(_:))))
            m.addItem(.separator())
        }
        if model.isSearching || model.kind.isResultList {
            m.addItem(command("Open Path", "document-open-folder", #selector(MainWindowController.ctxOpenPath(_:)), obj: item.url))
            m.addItem(command("Open Path in New Tab", "tab-new", #selector(MainWindowController.ctxOpenPathTab(_:)), obj: item.url))
            m.addItem(.separator())
        }
        // Launch Services only knows local files; remote items open through RemoteOpener (double-click).
        if local || (PlacesModel.isCloud(item.url) && !item.isBrowsableFolder) { addOpenWith(to: m, item: item) }
        cloudItems(m)
        if item.isSymlink || MainWindowController.isAlias(item) {
            m.addItem(command("Show Original", "document-open-folder", #selector(MainWindowController.showOriginal(_:))))
        }
        if single && item.isPackage {
            m.addItem(command("Show Package Contents", "folder-open", #selector(MainWindowController.showPackageContents(_:))))
        }
        if single && item.isBrowsableFolder {
            m.addItem(sub("Create New", "list-add", MainWindowController.createNewMenu()))
        }
        m.addItem(.separator())
        m.addItem(command("Cut", "edit-cut", #selector(MainWindowController.cut(_:))))
        m.addItem(command("Copy", "edit-copy", #selector(MainWindowController.copy(_:))))
        m.addItem(command("Copy Location", "link", #selector(MainWindowController.copyLocation(_:))))
        m.addItem(command("Add to Shelf", "bookmarks", #selector(MainWindowController.addToShelf(_:))))
        if single && item.isBrowsableFolder {
            m.addItem(
                command("Paste Into Folder", "edit-paste", #selector(MainWindowController.paste(_:)), obj: MainWindowController.pasteIntoFolder))
        }
        gitItems(m, item, single)
        if canCompareFiles {
            m.addItem(command("Compare Files…", "document-preview", #selector(MainWindowController.compareFiles(_:))))
        }
        m.addItem(command("Duplicate Here", "edit-duplicate", #selector(MainWindowController.duplicateItem(_:))))
        m.addItem(command("Make Alias", "insert-link", #selector(MainWindowController.makeAlias(_:))))
        m.addItem(command("Rename…", "edit-rename", #selector(MainWindowController.renameItem(_:))))
        if !single {
            m.addItem(
                command("New Folder with Selection (\(sel.count) Items)", "folder-new", #selector(MainWindowController.newFolderWithSelection(_:))))
        }
        if single && item.isBrowsableFolder && !PlacesModel.shared.contains(item.url) {
            m.addItem(command("Add to Places", "bookmark-new", #selector(MainWindowController.addToPlaces(_:))))
        }
        m.addItem(.separator())
        m.addItem(command("Move to Trash", "user-trash", #selector(MainWindowController.moveToTrash(_:))))
        if sel.contains(where: { FileOperationsController.isApplication($0.url) }) {
            m.addItem(command("Remove App and Leftovers…", "trash-empty", #selector(MainWindowController.removeAppAndLeftovers(_:))))
        }
        // ⇧ turns Move to Trash into Delete (Settings › Context Menu can show it permanently).
        let del = command("Delete", "edit-delete", #selector(MainWindowController.deleteItem(_:)), mods: .shift)
        del.isAlternate = true
        m.addItem(del)
        m.addItem(.separator())
        if single && item.isBrowsableFolder {
            m.addItem(command("Open Terminal Here", "utilities-terminal", #selector(MainWindowController.openTerminalHere(_:))))
        }
        m.addItem(command("Compress", "archive-insert", #selector(MainWindowController.compress(_:))))
        if MainWindowController.extractableExtensions.contains(item.fileExtension.lowercased()) {
            m.addItem(command("Extract Here", "archive-extract", #selector(MainWindowController.extractHere(_:))))
        }
        if single, local, item.utType?.conforms(to: .image) == true {
            m.addItem(command("Set Desktop Picture", "preferences-desktop-wallpaper", #selector(MainWindowController.setDesktopPicture(_:))))
        }
        m.addItem(.separator())
        // Finder tags live in extended attributes: local items only.
        if sel.allSatisfy({ $0.url.isFileURL }) {
            if let tagToggle { m.addItem(TagDotsView.menuItem(for: sel, action: tagToggle)) }
            m.addItem(sub("Tags", "tag", tags(sel)))
        }
        m.addItem(command("Share…", "document-share", #selector(MainWindowController.shareItems(_:))))
        m.addItem(command("AirDrop…", "airdrop", #selector(MainWindowController.airDropItems(_:))))
        m.addItem(command("Quick Look", "document-preview", #selector(MainWindowController.quickLook(_:))))
        if hasOtherView {
            m.addItem(.separator())
            m.addItem(command("Copy to Other View", "edit-copy", #selector(MainWindowController.copyToOtherView(_:))))
            m.addItem(command("Move to Other View", "edit-move", #selector(MainWindowController.moveToOtherView(_:))))
        }
        m.addItem(.separator())
        m.addItem(command("Get Info", "document-properties", #selector(MainWindowController.properties(_:))))
        return m
    }

    /// Folders get an "Open With" list of apps; files get "Open with <default>" plus the list.
    static func addOpenWith(to m: NSMenu, item: FileItem) {
        let ws = NSWorkspace.shared
        let associationURL = item.url.isFileURL ? item.url : URL(fileURLWithPath: "/tmp").appendingPathComponent(item.name)
        if item.isBrowsableFolder && !item.isApplication {
            let apps = ws.urlsForApplications(toOpen: associationURL).filter { $0.lastPathComponent != "Finder.app" }.prefix(12)
            guard !apps.isEmpty else { return }
            let sm = NSMenu()
            for a in apps { sm.addItem(openWithItem(a)) }
            m.addItem(sub("Open With", "document-open", sm))
            return
        }
        let def = ws.urlForApplication(toOpen: associationURL)
        if let d = def {
            let it = openWithItem(d)
            it.title = "Open with \(Self.appName(d))"
            m.addItem(it)
        }
        let others = ws.urlsForApplications(toOpen: associationURL).filter { $0 != def }.prefix(15)
        let sm = NSMenu()
        for a in others { sm.addItem(openWithItem(a)) }
        if !others.isEmpty { sm.addItem(.separator()) }
        sm.addItem(command("Other Application…", nil, #selector(MainWindowController.ctxOpenWithOther(_:))))
        m.addItem(sub("Open With", "document-open", sm))
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func openWithItem(_ app: URL) -> NSMenuItem {
        let it = NSMenuItem(title: Self.appName(app), action: #selector(MainWindowController.ctxOpenWith(_:)), keyEquivalent: "")
        it.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        it.image = icon
        return it
    }

    static func sortMenu() -> NSMenu {
        let m = NSMenu(title: "Sort By")
        for role in ItemRole.menuRoles where role != .tags {
            m.addItem(command(role.title, nil, #selector(MainWindowController.sortBy(_:)), obj: role.rawValue))
        }
        let other = NSMenu()
        for role in ItemRole.otherRoles { other.addItem(command(role.title, nil, #selector(MainWindowController.sortBy(_:)), obj: role.rawValue)) }
        m.addItem(sub("Other", nil, other))
        m.addItem(.separator())
        m.addItem(command("A-Z", "view-sort-ascending", #selector(MainWindowController.setSortAscending(_:))))
        m.addItem(command("Z-A", "view-sort-descending", #selector(MainWindowController.setSortDescending(_:))))
        m.addItem(.separator())
        m.addItem(command("Folders First", nil, #selector(MainWindowController.toggleFoldersFirst(_:))))
        m.addItem(command("Hidden Files Last", nil, #selector(MainWindowController.toggleHiddenLast(_:))))
        return m
    }

    static func groupMenu() -> NSMenu {
        let m = NSMenu(title: "Group By")
        m.addItem(command("None", nil, #selector(MainWindowController.groupBy(_:))))
        m.addItem(command("Same as Sort", nil, #selector(MainWindowController.groupBy(_:)), obj: "same"))
        m.addItem(.separator())
        for role in ItemRole.menuRoles where role != .tags {
            m.addItem(command(role.title, nil, #selector(MainWindowController.groupBy(_:)), obj: role.rawValue))
        }
        return m
    }

    /// Settings › Context Menu: hide switched-off entries, add Copy To / Move To, show Delete next to Trash.
    static func applySettings(_ m: NSMenu, hasItem: Bool, destinations: ((Bool) -> NSMenu)? = nil) {
        let s = Settings.shared
        let titles: [ContextMenuEntry: [String]] = [
            .addToPlaces: ["Add to Places"], .copyLocation: ["Copy Location"], .duplicate: ["Duplicate Here"],
            .openInNewTab: ["Open in New Tab", "Open in New Tabs", "Open Path in New Tab"], .openInNewWindow: ["Open in New Window"],
            .openInSplit: ["Open in Split View"], .openTerminal: ["Open Terminal Here"], .otherView: ["Copy to Other View", "Move to Other View"],
            .sortBy: ["Sort By", "Group By"], .viewMode: ["View Mode", "Adjust View Display Style…"], .compress: ["Compress", "Extract Here"],
            .tags: ["Tags"],
            .share: ["Share…", "AirDrop…"], .quickLook: ["Quick Look"],
        ]
        for (entry, names) in titles where !s.contextMenuShows(entry) {
            for it in m.items where names.contains(it.title) { m.removeItem(it) }
        }
        if s.contextMenuShows(.deleteAlongsideTrash), let del = m.items.first(where: { $0.title == "Delete" && $0.isAlternate }) {
            del.isAlternate = false
            del.keyEquivalentModifierMask = []
        }
        if hasItem, let destinations, s.contextMenuShows(.copyMoveTo), let idx = m.items.firstIndex(where: { $0.title == "Move to Trash" }) {
            m.insertItem(sub("Copy To", "edit-copy", destinations(false)), at: max(0, idx - 1))
            m.insertItem(sub("Move To", "edit-move", destinations(true)), at: max(0, idx))
        }
        tidy(m)
    }

    static func tidy(_ m: NSMenu) {
        var lastWasSep = true
        for it in m.items {
            if it.isSeparatorItem { if lastWasSep { m.removeItem(it) } else { lastWasSep = true } } else { lastWasSep = false }
        }
        if let last = m.items.last, last.isSeparatorItem { m.removeItem(last) }
    }

    /// Dolphin's "Copy To / Move To" targets: places, recent folders, the other view, or a chosen folder.
    static func destinationMenu(other: URL? = nil, move: Bool) -> NSMenu {
        let m = NSMenu()
        var seen = Set<String>()
        func add(_ title: String, _ url: URL, _ icon: String) {
            guard url.isFileURL, !seen.contains(url.path) else { return }
            seen.insert(url.path)
            m.addItem(command(title, icon, #selector(MainWindowController.copyOrMoveTo(_:)), tag: move ? 1 : 0, obj: url))
        }
        if let other { add("Other View (\(other.lastPathComponent))", other, "view-split-left-right") }
        for e in PlacesModel.shared.allEntries where !e.hidden && e.url.isFileURL && e.icon != "user-trash" { add(e.title, e.url, e.icon) }
        let recent = RecentLocations.shared.urls.prefix(6)
        if !recent.isEmpty { m.addItem(.separator()) }
        for u in recent { add(u.lastPathComponent, u, IconTheme.folderIconName(u)) }
        m.addItem(.separator())
        m.addItem(command("Browse…", "document-open-folder", #selector(MainWindowController.copyOrMoveTo(_:)), tag: move ? 1 : 0))
        return m
    }

    static func tagsMenu(for items: [FileItem]) -> NSMenu {
        let m = NSMenu()
        let colors: [(String, NSColor)] = [
            ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
            ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
        ]
        let current = Set(items.flatMap { MainWindowController.tagNames(of: $0.url) })
        for (name, color) in colors {
            let it = command(name, nil, #selector(MainWindowController.setTag(_:)), obj: name)
            it.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            it.state = current.contains(name) ? .on : .off
            m.addItem(it)
        }
        return m
    }

}
