import AppKit
import PorpoiseCore
import PorpoiseServices

extension DesktopWindowController {
    private var selectedItems: [FileItem] { model?.selectedItems ?? [] }
    private var selectedURLs: [URL] { selectedItems.map(\.url) }
    private var actionWindow: NSWindow? { nil }

    func desktopMenu(for index: Int?) -> NSMenu {
        guard let model else { return NSMenu() }
        let item = index.flatMap { model.rows.indices.contains($0) ? model.rows[$0].item : nil }
        let menu =
            item.map {
                FileContextMenu.file($0, model: model, tags: { FileContextMenu.tagsMenu(for: $0) }, tagToggle: { [weak self] in self?.toggleTag($0) })
            }
            ?? FileContextMenu.background(sort: FileContextMenu.sortMenu(), group: NSMenu(), viewModes: NSMenu())
        if item == nil {
            menu.insertItem(
                .make("Add Application Shortcut…", #selector(addApplicationShortcut(_:)), icon: "insert-link"),
                at: menu.items.firstIndex(where: \.isSeparatorItem) ?? menu.items.count)
        }
        // Surface navigation, grouping, other-pane operations and app cleanup do not apply to a pinned desktop grid.
        let forbidden: Set<Selector> = [
            #selector(MainWindowController.removeAppAndLeftovers(_:)), #selector(MainWindowController.emptyTrash(_:)),
        ]
        func bind(_ menu: NSMenu) {
            for entry in menu.items {
                if let submenu = entry.submenu {
                    bind(submenu)
                    if submenu.items.isEmpty { menu.removeItem(entry) }
                } else if let action = entry.action {
                    if forbidden.contains(action) || !responds(to: action) { menu.removeItem(entry) } else { entry.target = self }
                }
            }
            FileContextMenu.tidy(menu)
        }
        FileContextMenu.applySettings(menu, hasItem: item != nil) { FileContextMenu.destinationMenu(move: $0) }
        // Expose both disposal choices on the desktop; their actions and confirmations remain shared.
        menu.items.first { $0.action == #selector(deleteItem(_:)) }?.isAlternate = false
        bind(menu)
        if let item {
            let show = NSMenuItem.make("Show in Porpoise", #selector(showInPorpoise(_:)), icon: "document-open-folder", obj: item.url)
            show.target = self; menu.addItem(show)
        }
        menu.addItem(.separator())
        let corners = NSMenu(title: "Start Corner")
        for (tag, corner) in DesktopGridCorner.allCases.enumerated() {
            let entry = NSMenuItem.make(corner.title, #selector(menuCorner(_:)), tag: tag)
            entry.target = self; entry.state = corner == gridPreferences.corner ? .on : .off; corners.addItem(entry)
        }
        menu.addItem(.submenu("Start Corner", icon: "view-list-icons", corners))
        for entry in [
            NSMenuItem.make("Refresh", #selector(MainWindowController.reloadView(_:)), icon: "view-refresh"),
            .make("Disable Desktop Mode", #selector(disableMode), icon: "tab-close"),
        ] {
            entry.target = self; menu.addItem(entry)
        }
        // The same shortcut registry as the browser, after desktop-only commands were bound explicitly.
        MenuCommandRegistry.shared.apply(to: menu)
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model, let action = item.action else { return false }
        switch action {
        case #selector(emptyTrash(_:)), #selector(removeAppAndLeftovers(_:)): return false
        case #selector(paste(_:)): return !FileOperationsController.shared.clipboardURLs.isEmpty
        case #selector(sortBy(_:)): item.state = (item.representedObject as? String) == model.props.sortRole.rawValue ? .on : .off
        case #selector(setSortAscending(_:)): item.state = model.props.sortOrder == .ascending ? .on : .off
        case #selector(setSortDescending(_:)): item.state = model.props.sortOrder == .descending ? .on : .off
        case #selector(toggleFoldersFirst(_:)): item.state = model.props.foldersFirst ? .on : .off
        case #selector(toggleHiddenLast(_:)): item.state = model.props.hiddenLast ? .on : .off
        case #selector(copy(_:)), #selector(cut(_:)), #selector(renameItem(_:)), #selector(duplicateItem(_:)), #selector(quickLook(_:)),
            #selector(moveToTrash(_:)), #selector(deleteItem(_:)):
            return !selectedItems.isEmpty
        default: break
        }
        return true
    }

    @objc func addApplicationShortcut(_ sender: Any?) {
        guard model != nil else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Add Shortcut"; panel.message = "Choose an application to add to the desktop"
        guard panel.runModal() == .OK, let application = panel.url else { return }
        do { _ = try createApplicationShortcut(to: application) } catch {
            FileOperationsController.shared.ui?.showErrors(["Could not create the shortcut: \(error.localizedDescription)"], window: actionWindow)
        }
    }

    @discardableResult func createApplicationShortcut(to application: URL) throws -> URL {
        guard let model else { throw CocoaError(.userCancelled) }
        guard application.isFileURL, try application.resourceValues(forKeys: [.isApplicationKey]).isApplication == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Choose a macOS application (.app)."])
        }
        let alias = try MainWindowController.createAlias(
            of: application, in: model.location, named: application.deletingPathExtension().lastPathComponent)
        FileOperationsController.shared.pushUndo(.created([alias]))
        FileOperationsController.notifyChanged([alias])
        model.selection = [alias]; model.reload()
        return alias
    }

    @objc func showOriginal(_ sender: Any?) {
        if let item = selectedItems.first, let target = MainWindowController.resolvedTarget(of: item) { AppDelegate.shared.reveal([target]) }
    }

    @objc func copy(_ sender: Any?) { FileOperationsController.shared.copy(selectedURLs, cut: false) }
    @objc func cut(_ sender: Any?) { FileOperationsController.shared.copy(selectedURLs, cut: true) }
    @objc func copyLocation(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? model.map { [$0.location] } ?? [] : selectedURLs
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LocationNaming.clipboardText(for: urls), forType: .string)
    }
    @objc func paste(_ sender: NSMenuItem?) {
        guard let model else { return }
        let intoFolder = sender?.representedObject as? String == MainWindowController.pasteIntoFolder
        let destination = intoFolder && selectedItems.count == 1 && selectedItems[0].isBrowsableFolder ? selectedItems[0].url : model.location
        FileOperationsController.shared.paste(into: destination, window: actionWindow) { [weak self] urls in
            self?.model?.selection = Set(urls); self?.model?.reload()
        }
    }
    @objc func duplicateItem(_ sender: Any?) {
        guard let model else { return }
        FileOperationsController.shared.run(.copy, selectedURLs, to: model.location, window: actionWindow) { [weak self] urls in
            self?.model?.selection = Set(urls); self?.model?.reload()
        }
    }
    @objc func createFolder(_ sender: Any?) { createItem(.folder) }
    @objc func createFile(_ sender: NSMenuItem) { if let kind = NewItemKind(rawValue: sender.tag) { createItem(kind) } }
    private func createItem(_ kind: NewItemKind) {
        guard let model else { return }
        NewItemDialog.run(kind: kind, in: model.location, window: actionWindow, existingNames: Set(model.items.map(\.name))) { [weak self] url in
            FileOperationsController.shared.pushUndo(.created([url]))
            FileOperationsController.notifyChanged([url])
            self?.model?.selection = [url]; self?.model?.reload()
        }
    }
    @objc func renameItem(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        if selectedItems.count > 1 {
            BatchRenameDialog.run(selectedURLs, window: actionWindow) { [weak self] urls in
                self?.model?.selection = Set(urls); self?.model?.reload()
            }
        } else if Settings.shared.renameInline {
            (activeGrid ?? grids.first)?.beginRename(item.url)
        } else {
            ItemRenaming.prompt(item, window: actionWindow) { [weak self] name in
                guard let self, let grid = self.activeGrid ?? self.grids.first else { return }
                self.itemList(grid, rename: item, to: name)
            }
        }
    }
    @objc func copyOrMoveTo(_ sender: NSMenuItem) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let run: (URL) -> Void = { [weak self] destination in
            FileOperationsController.shared.run(sender.tag == 1 ? .move : .copy, urls, to: destination, window: self?.actionWindow)
        }
        if let destination = sender.representedObject as? URL { run(destination); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = sender.tag == 1 ? "Move Here" : "Copy Here"
        if panel.runModal() == .OK, let url = panel.url { run(url) }
    }
    @objc func reloadView(_ sender: Any?) { reload() }
    @objc func openSelected(_ sender: Any?) {
        guard let grid = activeGrid ?? grids.first else { return }
        itemList(grid, open: selectedItems, inNewTab: false)
    }
    @objc func closeCurrentTab(_ sender: Any?) {
        // Closing browser windows must not remove the desktop surfaces.
    }
    @objc func setTag(_ sender: NSMenuItem) { if let name = sender.representedObject as? String { toggleTag(name) } }
    private func toggleTag(_ name: String) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FinderTags.toggleAsync(name, on: urls) { [weak self] failures in
            self?.model?.refreshTags()
            self?.grids.forEach { $0.needsDisplay = true }
            if let first = failures.first {
                FileOperationsController.shared.ui?.showErrors(
                    ["Couldn’t change tags on \(FileFormat.itemCount(failures.count)). \(first.message)"], window: self?.actionWindow)
            }
        }
    }
    @objc func shareItems(_ sender: Any?) { shareSelection(.picker) }
    @objc func airDropItems(_ sender: Any?) { shareSelection(.airDrop) }
    private func shareSelection(_ mode: SharingCoordinator.Mode) {
        guard let grid = activeGrid ?? grids.first, let first = selectedURLs.first else { return }
        SharingCoordinator.shared.share(selectedURLs, mode: mode, from: grid, rect: grid.rect(for: first) ?? grid.visibleRect)
    }
    @objc func properties(_ sender: Any?) {
        guard let model else { return }
        PropertiesWindow.show(
            urls: selectedURLs.isEmpty ? [model.location] : selectedURLs, items: selectedItems, showingHidden: model.props.showHidden)
    }
    @objc func quickLook(_ sender: Any?) {
        if spacePreview?.isVisible == true { spacePreview?.close(); return }
        guard let grid = activeGrid ?? grids.first, let window = grid.window, !selectedItems.isEmpty else { return }
        let panel = spacePreview ?? SpacePreviewPanel(); spacePreview = panel
        panel.onOpenWith = { item, app in NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        panel.show(selectedItems, relativeTo: window, source: selectedItems.first.flatMap { grid.iconScreenRect(for: $0.url) } ?? .zero)
    }
    @objc func ctxOpenInNewWindow(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            AppDelegate.shared.openDesktopFolders(
                [url], inTabs: false, maximized: Settings.shared.desktopOpenMaximized, screen: activeGrid?.window?.screen)
        }
    }
    @objc func ctxOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func ctxOpenWithOther(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.application]
        panel.prompt = "Open"; panel.message = "Choose an application to open the selected items"
        if panel.runModal() == .OK, let app = panel.url {
            let entry = NSMenuItem(); entry.representedObject = app; ctxOpenWith(entry)
        }
    }
    @objc func addToShelf(_ sender: Any?) { _ = ShelfStore.shared.add(selectedURLs) }
    @objc func addToPlaces(_ sender: Any?) {
        guard let model else { return }
        for url in selectedItems.filter(\.isBrowsableFolder).map(\.url).isEmpty
            ? [model.location] : selectedItems.filter(\.isBrowsableFolder).map(\.url)
        {
            PlacesModel.shared.add(url)
        }
    }
    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let role = ItemRole(rawValue: raw) else { return }
        sort { $0.sortRole = role }
    }
    @objc func setSortAscending(_ sender: Any?) { sort { $0.sortOrder = .ascending } }
    @objc func setSortDescending(_ sender: Any?) { sort { $0.sortOrder = .descending } }
    @objc func toggleFoldersFirst(_ sender: Any?) { sort { $0.foldersFirst.toggle() } }
    @objc func toggleHiddenLast(_ sender: Any?) { sort { $0.hiddenLast.toggle() } }
    private func sort(_ update: (inout ViewProperties) -> Void) { arrangeGrid(update) }
    @objc func adjustViewStyle(_ sender: Any?) {
        guard let model else { return }
        AdjustViewDialog.run(model: model, window: actionWindow, fixedMode: .icons)
    }

    // Explicit local blockers prevent the main menu from finding an unrelated browser as its action target.
    @objc func moveToTrash(_ sender: Any?) {
        guard !selectedURLs.isEmpty, activeGrid?.isRenaming != true else { return }
        FileOperationsController.shared.trash(selectedURLs, window: actionWindow)
    }
    @objc func deleteItem(_ sender: Any?) {
        guard !selectedURLs.isEmpty, activeGrid?.isRenaming != true else { return }
        FileOperationsController.shared.delete(selectedURLs, window: actionWindow)
    }
    @objc func emptyTrash(_ sender: Any?) {}
    @objc func removeAppAndLeftovers(_ sender: Any?) {}

    func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) {
        guard LocalFileOpening.confirmMultiple(count: items.count) else { return }
        let folders = items.filter(\.isBrowsableFolder).map(\.url)
        AppDelegate.shared.openDesktopFolders(
            folders, inTabs: inNewTab || Settings.shared.desktopFoldersInTabs,
            maximized: Settings.shared.desktopOpenMaximized, screen: view.window?.screen)
        for item in items where !item.isBrowsableFolder { localFileOpening.open(item, window: actionWindow) {} }
    }
    func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? {
        activeGrid = view as? DesktopGridView
        return desktopMenu(for: item.flatMap { model?.index(of: $0.url) })
    }
    func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {}
    func itemList(_ view: ItemListView, rename item: FileItem, to name: String) {
        itemRenaming.rename(item, to: name, showingHidden: model?.props.showHidden ?? false, window: actionWindow) { [weak self] url in
            if let url { self?.renamedPosition(from: item.url, to: url); self?.model?.selection = [url] }; self?.model?.reload()
        }
    }
    func itemListDidBecomeActive(_ view: ItemListView) { activeGrid = view as? DesktopGridView }
    func itemList(_ view: ItemListView, hovered item: FileItem?) {}
    func itemListBackgroundDoubleClicked(_ view: ItemListView) {}
    func itemList(_ view: ItemListView, middleClicked item: FileItem) { itemList(view, open: [item], inNewTab: true) }
    func itemListQuickLook(_ view: ItemListView) { activeGrid = view as? DesktopGridView; quickLook(nil) }
}
