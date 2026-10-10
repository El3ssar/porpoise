import AppKit
import PorpoiseCore
import PorpoiseServices

/// Dolphin's Folders panel (F7): a folder tree that follows the current location.
final class FoldersPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = FolderOutlineView()
    private let scroll = NSScrollView()
    private var root: Node
    var onNavigate: ((URL, Bool) -> Void)?
    var currentURL: URL? { didSet { if currentURL != oldValue { followCurrent() } } }
    private var settingsObserver: NSObjectProtocol?

    private static let cellID = NSUserInterfaceItemIdentifier("folder")
    /// Settings this panel depends on (nil: all settings were reset).
    private static let settingKeys: Set<String?> = ["foldersHome", "foldersHidden", nil]
    /// Entries looked at when guessing whether a folder has subfolders (it decides the disclosure triangle).
    private static let expandabilityScanLimit = 200

    /// A folder in the tree; children are listed lazily and cached until the tree is rebuilt.
    final class Node {
        let url: URL
        private(set) var children: [Node]?
        private var expandable: Bool?
        /// Children from before `invalidate()`, reused so their expansion state survives a re-list.
        private var staleChildren: [Node]?
        init(_ url: URL) { self.url = url }

        var name: String {
            guard url.path == "/" else { return url.lastPathComponent }
            return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/"
        }

        func load(showHidden: Bool) -> [Node] {
            if let c = children { return c }
            let old = Dictionary((staleChildren ?? []).map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            let c = Self.subfolderNames(of: url, showHidden: showHidden, limit: nil)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { old[$0] ?? Node(url.appendingPathComponent($0)) }
            children = c
            staleChildren = nil
            return c
        }

        /// Cheap check (first entries only) unless the children are already known.
        func isExpandable(showHidden: Bool) -> Bool {
            if let c = children { return !c.isEmpty }
            if let e = expandable { return e }
            let e = !Self.subfolderNames(of: url, showHidden: showHidden, limit: FoldersPanel.expandabilityScanLimit, firstOnly: true).isEmpty
            expandable = e
            return e
        }

        /// Adds a hidden subfolder that the view is in (or under), so the tree can show the way there.
        func reveal(_ name: String, showHidden: Bool) -> Node {
            var c = load(showHidden: showHidden)
            if let n = c.first(where: { $0.url.lastPathComponent == name }) { return n }
            let n = Node(url.appendingPathComponent(name))
            c.append(n)
            c.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            children = c
            return n
        }

        /// Forgets the cached listing (the folder changed on disk).
        func invalidate() {
            staleChildren = children ?? staleChildren
            children = nil
            expandable = nil
        }

        /// Names of real subfolders (packages such as .app bundles are files here, as in the view). Hidden ones are
        /// dot folders and folders hidden in Finder (~/Library, /usr…), as in the view.
        private static func subfolderNames(of url: URL, showHidden: Bool, limit: Int?, firstOnly: Bool = false) -> [String] {
            var names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if !showHidden { names.removeAll { $0.hasPrefix(".") } }
            if let limit { names = Array(names.prefix(limit)) }
            var out: [String] = []
            for n in names {
                let v = try? url.appendingPathComponent(n).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey])
                guard v?.isDirectory == true, v?.isPackage != true, showHidden || v?.isHidden != true else { continue }
                out.append(n)
                if firstOnly { break }
            }
            return out
        }
    }

    override init(frame: NSRect) {
        root = Node(FileManager.default.homeDirectoryForCurrentUser)
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.target = self
        outline.action = #selector(clicked)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.appearance = NSAppearance(named: .darkAqua)
        addSubview(scroll)
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
            // Rebuilding collapses the tree, so only for the panel's own settings.
            if Self.settingKeys.contains(n.object as? String) { self?.resetRoot() }
        }
        resetRoot()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    deinit { settingsObserver.map(NotificationCenter.default.removeObserver) }

    private var showHidden: Bool { Settings.shared.foldersShowHidden }

    private static func isInHome(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path == home || url.path.hasPrefix(home + "/")
    }

    // MARK: Following the view

    private func resetRoot() {
        let inHome = currentURL.map(Self.isInHome) ?? true
        root = Node(Settings.shared.foldersLimitToHome && inHome ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: "/"))
        outline.reloadData()
        outline.expandItem(nil)
        followCurrent()
    }

    /// Expands down to the current folder and selects it.
    private func followCurrent() {
        guard let target = currentURL, target.isFileURL else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if Settings.shared.foldersLimitToHome && (root.url.path == home.path) != Self.isInHome(target) { resetRoot(); return }
        var chain: [URL] = []
        // The tree holds real folders: /tmp/x is shown as /private/tmp/x (symlinks are not folders here).
        var u = Self.realFolder(target)
        while u.path.count >= root.url.path.count && u.path != root.url.path {
            chain.insert(u, at: 0)
            u = u.deletingLastPathComponent()
        }
        var parent: Node?
        for c in chain {
            guard let n = child(of: parent, at: c) else { break }
            if let p = parent { outline.expandItem(p) }
            parent = n
        }
        guard let n = parent, case let row = outline.row(forItem: n), row >= 0 else {
            outline.deselectAll(nil)
            return
        }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// The folder with symlinks resolved (realpath keeps /private, unlike URL.resolvingSymlinksInPath).
    private static func realFolder(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        guard let r = realpath(std.path, nil) else { return std }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r))
    }

    /// The child folder at `url`; re-lists the parent once when it's missing (created since it was listed).
    private func child(of parent: Node?, at url: URL) -> Node? {
        let p = parent ?? root
        if let n = p.load(showHidden: showHidden).first(where: { $0.url.path == url.path }) { return n }
        p.invalidate()
        if let n = p.load(showHidden: showHidden).first(where: { $0.url.path == url.path }) {
            outline.reloadItem(parent, reloadChildren: true)
            return n
        }
        // A hidden folder (/Volumes, /private, ~/.config…) on the way to the view's folder is shown anyway, as the
        // path there would otherwise be missing from the tree.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            outline.reloadItem(parent, reloadChildren: true)
            return nil
        }
        let n = p.reveal(url.lastPathComponent, showHidden: showHidden)
        outline.reloadItem(parent, reloadChildren: true)
        return n
    }

    // MARK: Outline data

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? root).load(showHidden: showHidden).count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? root).load(showHidden: showHidden)[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isExpandable(showHidden: showHidden) ?? false
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let v = (o.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView) ?? makeCell()
        v.imageView?.image = Icons.shared.image(IconTheme.folderIconName(n.url), size: 16)
        v.textField?.stringValue = n.name
        return v
    }

    private func makeCell() -> NSTableCellView {
        let v = NSTableCellView()
        v.identifier = Self.cellID
        let img = NSImageView()
        img.frame = CGRect(x: 2, y: 4, width: 16, height: 16)
        let t = NSTextField(labelWithString: "")
        t.font = Theme.font
        t.textColor = Theme.windowText
        t.lineBreakMode = .byTruncatingTail
        t.frame = CGRect(x: 22, y: 3, width: 400, height: 17)
        t.autoresizingMask = [.width]
        v.addSubview(img)
        v.addSubview(t)
        v.imageView = img
        v.textField = t
        return v
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { BreezeRowView() }

    // MARK: Mouse

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        onNavigate?(n.url, NSEvent.modifierFlags.contains(.command))
    }

    /// Return opens the folder selected with the keyboard (⌘Return: in a new tab).
    private func openSelected() {
        guard let n = outline.item(atRow: outline.selectedRow) as? Node else { return }
        onNavigate?(n.url, NSEvent.modifierFlags.contains(.command))
    }

    /// Middle click opens in a new tab; other buttons (mouse back/forward) go up the responder chain.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        if let n = outline.item(atRow: row) as? Node { onNavigate?(n.url, true) }
    }
}

// MARK: - Context menu

extension FoldersPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let n = outline.item(atRow: outline.clickedRow) as? Node {
            let open = menu.addItem(withTitle: "Open in New Tab", action: #selector(openInTab(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = n.url; open.image = Icons.shared.menuIcon("tab-new")
            let props = menu.addItem(withTitle: "Properties", action: #selector(props(_:)), keyEquivalent: "")
            props.target = self; props.representedObject = n.url; props.image = Icons.shared.menuIcon("document-properties")
            menu.addItem(.separator())
        }
        let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHidden), keyEquivalent: "")
        hidden.target = self; hidden.state = Settings.shared.foldersShowHidden ? .on : .off
        let home = menu.addItem(withTitle: "Limit to Home Folder", action: #selector(toggleHome), keyEquivalent: "")
        home.target = self; home.state = Settings.shared.foldersLimitToHome ? .on : .off
    }

    @objc private func openInTab(_ s: NSMenuItem) { if let u = s.representedObject as? URL { onNavigate?(u, true) } }
    @objc private func props(_ s: NSMenuItem) { if let u = s.representedObject as? URL { PropertiesWindow.show(urls: [u]) } }
    @objc private func toggleHidden() { Settings.shared.foldersShowHidden.toggle() }
    @objc private func toggleHome() { Settings.shared.foldersLimitToHome.toggle() }
}

/// The tree; Return opens the selected folder (arrows only move the selection, like Dolphin's panel).
private final class FolderOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// Table row highlight drawn like Dolphin's Places/Folders panels.
final class BreezeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.placesSelectedFill.setFill()
        bounds.fill()
    }
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
