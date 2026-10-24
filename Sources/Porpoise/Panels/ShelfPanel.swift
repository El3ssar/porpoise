import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// Panels › Shelf (F8): references collected from any folder, search or server, kept until an operation runs on
/// them. Items that went missing or whose disk isn't connected stay on the shelf, shown as such.
final class ShelfPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// The folder the window shows (where Copy Here and Move Here put things).
    var currentFolder: (() -> URL?)?
    /// Opens a folder in the window.
    var openFolder: ((URL) -> Void)?

    private let store: ShelfStore
    private let shelves = NSPopUpButton()
    private let count = NSTextField(labelWithString: "")
    private let table = ShelfTableView()
    private let scroll = NSScrollView()
    private let copyHere = NSButton(title: "Copy Here", target: nil, action: nil)
    private let moveHere = NSButton(title: "Move Here", target: nil, action: nil)
    private let separator = NSView()
    private let hint = NSTextField(wrappingLabelWithString: "Drag items here, or choose Add to Shelf (⌥⌘S), to collect them from several places.")
    private var states: [UUID: ShelfItemState] = [:]
    private var observer: NSObjectProtocol?

    override convenience init(frame: NSRect) { self.init(frame: frame, store: .shared) }

    init(frame: NSRect, store: ShelfStore) {
        self.store = store
        super.init(frame: frame)
        // The panel's header, in the sidebar's section-title style ("Places", "Remote"): the shelf's name opens its menu.
        shelves.isBordered = false
        shelves.font = .systemFont(ofSize: Tokens.FontSize.small, weight: .semibold)
        shelves.contentTintColor = Theme.windowTextInactive
        shelves.setAccessibilityLabel("Shelf")
        shelves.target = self
        shelves.action = #selector(shelfChosen)
        count.font = .systemFont(ofSize: Tokens.FontSize.small)
        count.textColor = .secondaryLabelColor
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.rowHeight = 34
        table.allowsMultipleSelection = true
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(openSelected)
        table.target = self
        table.panel = self
        table.registerForDraggedTypes([.fileURL, .URL, .shelfItems])
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Regular size in a narrow sidebar: a short title with its glyph (the full name is the tooltip and VoiceOver label).
        for (b, title, symbol, label) in [
            (copyHere, "Copy", "doc.on.doc", "Copy Here"), (moveHere, "Move", "arrow.right.doc.on.clipboard", "Move Here"),
        ] {
            b.bezelStyle = .push
            b.title = title
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.setAccessibilityLabel(label)
            b.target = self
        }
        copyHere.action = #selector(copyToCurrent)
        moveHere.action = #selector(moveToCurrent)
        copyHere.toolTip = "Copy the selected items (all when none is selected) to the folder shown"
        moveHere.toolTip = "Move the selected items (all when none is selected) to the folder shown"
        hint.font = .systemFont(ofSize: Tokens.FontSize.callout)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        let header = NSStackView(views: [shelves, NSView(), count])
        // The shelf's name keeps a readable width; the count gives way.
        shelves.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        // Its menu's longest command (Rename Shelf…) mustn't decide its width.
        let cap = shelves.widthAnchor.constraint(lessThanOrEqualToConstant: 120)
        cap.priority = .required
        cap.isActive = true
        shelves.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [copyHere, moveHere])
        footer.distribution = .fillEqually
        footer.spacing = 6
        // A hairline above the panel: Places above it reads as scrolled, not cut off.
        separator.wantsLayer = true
        Theme.whenChanged(separator) { [weak self] in self?.separator.layer?.backgroundColor = Theme.separator.cgColor }
        for v in [separator, header, scroll, footer, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            separator.heightAnchor.constraint(equalToConstant: 1),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            hint.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        observer = NotificationCenter.default.addObserver(forName: ShelfStore.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebarBackground.setFill()
        bounds.fill()
    }

    // MARK: Contents

    private var items: [ShelfItem] { store.current.items }

    func reload() {
        let selected = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        states = Dictionary(uniqueKeysWithValues: store.current.items.map { ($0.id, store.state(of: $0)) })
        shelves.removeAllItems()
        for s in store.shelves { shelves.addItem(withTitle: s.name) }
        shelves.selectItem(at: store.currentIndex)
        shelves.menu?.addItem(.separator())
        for (title, action) in [
            ("New Shelf…", #selector(newShelf)), ("Rename Shelf…", #selector(renameShelf)), ("Delete Shelf", #selector(deleteShelf)),
        ] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            shelves.menu?.addItem(mi)
        }
        let missing = items.filter { states[$0.id]?.problem != nil }.count
        // Short, for a narrow sidebar; the tooltip says it in full.
        count.stringValue = items.isEmpty ? "" : missing > 0 ? "\(missing) missing" : FileFormat.itemCount(items.count)
        count.toolTip =
            items.isEmpty
            ? nil
            : FileFormat.itemCount(items.count) + (missing > 0 ? ", \(missing) unavailable (missing or disconnected)" : "")
        count.textColor = missing > 0 ? Theme.negativeText : .secondaryLabelColor
        table.reloadData()
        table.selectRowIndexes(IndexSet(items.indices.filter { selected.contains(items[$0].id) }), byExtendingSelection: false)
        hint.isHidden = !items.isEmpty
        copyHere.isEnabled = !items.isEmpty
        moveHere.isEnabled = !items.isEmpty
    }

    /// The selected items, or all of them when none is selected.
    private var chosen: [ShelfItem] {
        let rows =
            table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        let sel = rows.compactMap { items.indices.contains($0) ? items[$0] : nil }
        return sel.isEmpty ? items : sel
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let state = states[item.id] ?? .missing
        let v = ShelfRowView()
        let url = state.url ?? item.url
        let file = url.isFileURL ? FileItem.load(url) : nil
        v.icon.image =
            file.map { Icons.shared.image(for: $0, size: 22) }
            ?? Icons.shared.image(url.isFileURL ? "unknown" : "folder-remote", size: 22) ?? NSImage()
        v.name.stringValue = LocationNaming.name(for: url)
        if let problem = state.problem {
            // What's wrong first: a long location is cut, not the problem.
            v.detail.stringValue = problem + " — " + LocationNaming.context(for: item.url)
            v.detail.lineBreakMode = .byTruncatingTail
            v.detail.textColor = Theme.negativeText
            v.name.textColor = .disabledControlTextColor
            v.icon.alphaValue = 0.4
        } else {
            v.detail.stringValue = LocationNaming.context(for: url)
        }
        v.toolTip = LocationNaming.address(for: url)
        return v
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let u = states[items[row].id]?.url else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(u.absoluteString, forType: u.isFileURL ? .fileURL : .URL)
        pb.setString(items[row].id.uuidString, forType: .shelfItems)
        return pb
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation
    )
        -> NSDragOperation
    {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === table ? .move : .link
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if info.draggingSource as? NSTableView === table {
            let ids = Set((pb.pasteboardItems ?? []).compactMap { $0.string(forType: .shelfItems).flatMap(UUID.init) })
            store.move(ids, to: row)
            return true
        }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        return store.add(urls.filter { $0.isFileURL || RemoteFS.isRemote($0) }) > 0
    }

    // MARK: Actions

    @objc private func shelfChosen() {
        if shelves.indexOfSelectedItem < store.shelves.count { store.select(shelves.indexOfSelectedItem) }
    }

    @objc private func newShelf() {
        ask("New Shelf", value: "Shelf \(store.shelves.count + 1)", button: "Create") { [weak self] in self?.store.newShelf(named: $0) }
    }

    @objc private func renameShelf() {
        ask("Rename Shelf", value: store.current.name, button: "Rename") { [weak self] in self?.store.renameCurrent($0) }
    }

    @objc private func deleteShelf() {
        let a = NSAlert()
        a.messageText = "Delete the shelf “\(store.current.name)”?"
        a.informativeText = "Only the shelf and its references go; the files themselves stay where they are."
        a.addButton(withTitle: "Delete Shelf")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.store.deleteCurrent() } else { self?.reload() } }
    }

    private func ask(_ title: String, value: String, button: String, _ done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(string: value)
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            if r == .alertFirstButtonReturn { done(field.stringValue) } else { self?.reload() }
        }
    }

    /// Tells what an operation leaves out (missing or disconnected items), which stay on the shelf.
    private func report(_ plan: ShelfPlan) {
        guard let text = plan.skippedText, let w = window else { return }
        let a = NSAlert()
        a.messageText = text
        a.informativeText = "They stay on the shelf: reconnect the disk or remove them from the shelf."
        a.beginSheetModal(for: w)
    }

    @objc func copyToCurrent() { transfer(.copy) }
    @objc func moveToCurrent() { transfer(.move) }

    private func transfer(_ kind: FileOperationKind) {
        guard let folder = currentFolder?() else { return }
        let picked = chosen
        let plan = store.plan(picked)
        report(plan)
        guard !plan.urls.isEmpty else { return }
        let sources = Dictionary(uniqueKeysWithValues: picked.compactMap { item in store.state(of: item).url.map { (item.id, $0) } })
        let store = store
        FileOperationsController.shared.run(
            kind, plan.urls, to: folder, window: window,
            moved: { results in
                store.moved(results, sources: sources)
            })
    }

    @objc func openSelected() {
        let plan = store.plan(chosen)
        report(plan)
        for u in plan.urls {
            var isDir: ObjCBool = false
            if u.isFileURL, FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                (try? u.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
            {
                openFolder?(u)
            } else if u.isFileURL {
                NSWorkspace.shared.open(u)
            } else {
                openFolder?(u.hasDirectoryPath ? u : u.deletingLastPathComponent())
            }
        }
    }

    @objc private func reveal() {
        let plan = store.plan(chosen)
        report(plan)
        if let first = plan.urls.first(where: \.isFileURL) { AppDelegate.shared.reveal([first]) }
    }

    @objc private func rename() {
        let plan = store.plan(chosen)
        report(plan)
        let local = plan.urls.filter(\.isFileURL)
        guard !local.isEmpty, let w = window else { return }
        BatchRenameDialog.run(local, window: w) { [weak self] renamed in
            // The bookmarks find the renamed items; refresh what's shown.
            _ = renamed
            self?.reload()
        }
    }

    @objc private func share() { shareChosen(mode: .picker) }
    @objc private func airDrop() { shareChosen(mode: .airDrop) }

    func shareChosen(mode: SharingCoordinator.Mode, using coordinator: SharingCoordinator = .shared) {
        let plan = store.plan(chosen)
        report(plan)
        // Do not share a subset when a bookmarked local item is unavailable.
        guard plan.skipped.isEmpty else { return }
        let row = max(0, table.selectedRow)
        coordinator.share(
            plan.urls, mode: mode, from: table,
            rect: row < table.numberOfRows ? table.rect(ofRow: row) : table.visibleRect)
    }

    @objc func removeChosen() {
        let picked = chosen
        // "Remove" with nothing selected would empty the shelf: that is Clear Shelf's job.
        guard table.selectedRowIndexes.count > 0 || table.clickedRow >= 0 else { return }
        removeWithUndo(Set(picked.map(\.id)))
    }

    @objc private func clearShelf() { removeWithUndo(Set(items.map(\.id))) }

    @objc private func removeUnavailable() { removeWithUndo(Set(items.filter { states[$0.id]?.problem != nil }.map(\.id))) }

    /// Takes items off the shelf at once; the window's message bar says what went and offers Undo.
    private func removeWithUndo(_ ids: Set<UUID>) {
        let shelf = store.current
        let gone = shelf.items.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        store.remove(ids)
        guard let bar = (window?.windowController as? MainWindowController)?.view.messageBar else { return }
        let what = gone.count == 1 ? "“\(gone[0].name)”" : FileFormat.itemCount(gone.count)
        bar.show("Removed \(what) from the shelf “\(shelf.name)”.", error: false, action: "Undo") { [weak self] in
            bar.dismiss()
            self?.store.restore(shelf.items, on: shelf.id)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasItems = !items.isEmpty
        let onItem = table.clickedRow >= 0
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        if onItem {
            add("Open", #selector(openSelected))
            add("Show in Folder", #selector(reveal))
            menu.addItem(.separator())
        }
        add(onItem ? "Copy Here" : "Copy All Here", #selector(copyToCurrent), enabled: hasItems)
        add(onItem ? "Move Here" : "Move All Here", #selector(moveToCurrent), enabled: hasItems)
        add("Rename…", #selector(rename), enabled: hasItems)
        add("Share…", #selector(share), enabled: hasItems)
        add("AirDrop…", #selector(airDrop), enabled: hasItems)
        menu.addItem(.separator())
        if onItem { add("Remove from Shelf", #selector(removeChosen)) }
        if items.contains(where: { states[$0.id]?.problem != nil }) { add("Remove Unavailable Items", #selector(removeUnavailable)) }
        add("Clear Shelf", #selector(clearShelf), enabled: hasItems)
    }

    // MARK: Services and the keyboard

    /// The selection (or the whole shelf) for Services (the context menu's and the app menu's).
    fileprivate var serviceURLs: [URL] { store.plan(chosen).urls.filter(\.isFileURL) }
}

/// The table of the shelf: Delete removes the selection; Services act on it.
final class ShelfTableView: NSTableView {
    weak var panel: ShelfPanel?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {  // ⌫ / ⌦
            panel?.removeChosen()
            return
        }
        if event.keyCode == 36 {
            panel?.openSelected()
            return
        }
        super.keyDown(with: event)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .fileURL || sendType == .string, !(panel?.serviceURLs.isEmpty ?? true) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let urls = panel?.serviceURLs, !urls.isEmpty else { return false }
        pboard.clearContents()
        pboard.writeObjects(urls as [NSURL])
        pboard.setString(LocationNaming.clipboardText(for: urls), forType: .string)
        return true
    }
}

/// Icon, name, and where it is (or what's wrong with it).
final class ShelfRowView: NSView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = Theme.font
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        for v in [icon, name, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension NSPasteboard.PasteboardType {
    /// Shelf items dragged within the shelf (reordering).
    static let shelfItems = NSPasteboard.PasteboardType("app.porpoise.shelf-item")
}
