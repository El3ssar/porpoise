import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import UniformTypeIdentifiers

final class DiskUsageWindow: DiskUtilityWindow {
    private let roots: [URL]
    private var tree: UsageTree?
    private var current = 0
    private var children: [Int] = []
    private var allocated = false
    let map = DiskTreemapView()
    let metric = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var bar: UtilityToolbar?
    /// How to look inside an item, and the fine print about the sizes (the map's help tag).
    static let hint = "Click a tile, or double-click a folder in the list, to look inside it."
    static let finePrint =
        "Hard links count once across the selection. Allocated bytes exclude directory metadata and may overlap across APFS clones; they are not guaranteed reclaimable space. Scans stay on selected volumes."
    init(roots: [URL]) {
        self.roots = roots
        super.init(
            title: "Disk Usage",
            columns: [("name", "Name", 360), ("logical", "Logical size", 150), ("allocated", "Allocated size", 150), ("files", "Unique files", 100)],
            sortable: true)
        // A real toolbar (UI-10): Back as a chevron, the actions as symbols, the map's measure as a pop-up.
        metric.target = self; metric.action = #selector(metricChanged)
        metric.addItems(withTitles: ["Logical Size", "Allocated Size"])
        if let window {
            bar = UtilityToolbar.install(
                [
                    .button(id: "back", label: "Back", symbol: "chevron.left", enabled: { [weak self] in self?.canGoBack ?? false }) {
                        [weak self] in self?.back()
                    },
                    .flexibleSpace,
                    .control(id: "metric", label: "Map By", view: metric),
                    .button(id: "rescan", label: "Rescan", symbol: "arrow.clockwise") { [weak self] in self?.scan() },
                    .button(id: "reveal", label: "Show in Folder", symbol: "folder", enabled: { [weak self] in self?.selectedURL != nil }) {
                        [weak self] in self?.reveal()
                    },
                    .button(
                        id: "trash", label: "Move to Trash", symbol: "trash",
                        enabled: { [weak self] in self.map { !$0.busy && $0.selectedURL != nil } ?? false }
                    ) { [weak self] in self?.trash() },
                ], on: window, name: "DiskUsage")
        }
        toolbar.isHidden = true
        // Sized once the toolbar is on: adding one later grows the window by its height.
        window?.setContentSize(NSSize(width: 1000, height: 740)); window?.minSize.height = 720; window?.center()
        stack.insertArrangedSubview(map, at: 1)
        map.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; map.heightAnchor.constraint(equalToConstant: 200).isActive = true
        map.activate = { [weak self] id in self?.enter(id) }
        map.toolTip = Self.hint + "\n\n" + Self.finePrint
        table.target = self; table.doubleAction = #selector(openRow)
        emptyListState = ListState(title: "Folder is empty", symbol: "folder")
        scan()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func scan() {
        let roots = roots
        perform(
            { token, report in
                let scan = PhysicalTreeScanner.scan(roots, cancellation: token, progress: report)
                try token.check(); return (UsageTree(scan), scan.errors)
            },
            done: { [weak self] tree, errors in
                guard let self else { return }
                self.tree = tree; self.errors = errors; self.current = tree.nodes[0].children.count == 1 ? tree.nodes[0].children[0] : 0
                self.reload()
            })
    }
    /// The id of the item shown at this level with this name (tests, the bridge).
    func itemID(named name: String) -> Int? { map.items.first { $0.1 == name }?.0 }
    @objc private func metricChanged() { allocated = metric.indexOfSelectedItem == 1; reload() }
    override func workChanged() {
        bar?.validate()
        updateMapPlaceholder()
    }
    /// While a scan runs, the map says so; after it, a level of empty items says why there is nothing to draw. An empty
    /// folder says nothing here: the list already says it is empty, once is enough.
    private func updateMapPlaceholder() {
        map.placeholder =
            busy
            ? ListState(title: "Scanning…", symbol: "")
            : (children.isEmpty ? nil : ListState(title: "Nothing here takes up space", symbol: "square.dashed"))
    }
    func tableViewSelectionDidChange(_ notification: Notification) { bar?.validate() }
    private var canGoBack: Bool { tree.map { $0.nodes.indices.contains(current) && $0.nodes[current].parent != nil } ?? false }
    private func reload() {
        guard let tree, tree.nodes.indices.contains(current) else { return }
        children = tree.nodes[current].children
        let descriptor = table.sortDescriptors.first, ascending = descriptor?.ascending ?? false,
            key = descriptor?.key ?? (allocated ? "allocated" : "logical")
        children.sort { a, b in
            let left = tree.nodes[a], right = tree.nodes[b]
            let comparison: ComparisonResult
            if key == "name" {
                comparison = left.name.localizedStandardCompare(right.name)
            } else {
                let x = key == "files" ? Int64(left.files) : (key == "allocated" ? left.allocated : left.logical)
                let y = key == "files" ? Int64(right.files) : (key == "allocated" ? right.allocated : right.logical)
                comparison = x < y ? .orderedAscending : (x > y ? .orderedDescending : left.name.localizedStandardCompare(right.name))
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        rows = children.map { id in
            let n = tree.nodes[id]; return [n.name, FileFormat.size(n.logical), FileFormat.size(n.allocated), n.files.formatted()]
        }
        table.reloadData()
        updateEmptyState()
        updateMapPlaceholder()
        bar?.validate()
        map.folders = Set(children.filter { tree.nodes[$0].directory })
        map.items = children.map { id in (id, tree.nodes[id].name, allocated ? tree.nodes[id].allocated : tree.nodes[id].logical) }
        let node = tree.nodes[current]
        status.stringValue = Self.summary(
            place: Self.place(of: node.url, in: roots), logical: node.logical, allocated: node.allocated, files: node.files,
            hardLinkAliases: tree.hardLinkAliases, errors: errors.count)
        status.toolTip = node.url?.path
    }

    /// Where the map is, from the folder scanned ("Demo › Photos"), not a path from the root of the disk.
    static func place(of url: URL?, in roots: [URL]) -> String {
        guard let url else { return "Selection" }
        let path = url.standardizedFileURL.path
        for root in roots {
            let base = root.standardizedFileURL.path
            guard path == base || path.hasPrefix(base == "/" ? "/" : base + "/") else { continue }
            let rest = path.dropFirst(base.count).split(separator: "/").map(String.init)
            return ([root.lastPathComponent] + rest).joined(separator: " › ")
        }
        return url.lastPathComponent
    }

    /// The footer: the place and its sizes; hard-link aliases and errors only when there are some.
    static func summary(place: String, logical: Int64, allocated: Int64, files: Int, hardLinkAliases: Int, errors: Int) -> String {
        var parts = [
            place, "\(FileFormat.size(logical)) logical", "\(FileFormat.size(allocated)) allocated",
            "\(files.formatted()) \(files == 1 ? "file" : "files")",
        ]
        if hardLinkAliases > 0 { parts.append("\(hardLinkAliases.formatted()) hard-link \(hardLinkAliases == 1 ? "alias" : "aliases")") }
        if errors > 0 { parts.append("\(errors.formatted()) \(errors == 1 ? "error" : "errors")") }
        return parts.joined(separator: " · ")
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }
    private func enter(_ id: Int) {
        guard let tree, tree.nodes[id].directory else {
            if let index = children.firstIndex(of: id) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }; return
        }
        current = id; reload()
    }
    private func back() { guard let tree, let parent = tree.nodes[current].parent else { return }; current = parent; reload() }
    @objc private func openRow() { if children.indices.contains(table.clickedRow) { enter(children[table.clickedRow]) } }
    var selectedURL: URL? {
        guard children.indices.contains(table.selectedRow), let tree else { return nil }; return tree.nodes[children[table.selectedRow]].url
    }
    /// In a Porpoise window, never Finder.
    private func reveal() { if let url = selectedURL { AppDelegate.shared.reveal([url]) } }
    private func trash() {
        guard !busy, let url = selectedURL else { return }
        FileOperationsController.shared.trash([url], window: window)
        FolderUsageCache.shared.invalidate(below: url.deletingLastPathComponent())
        status.stringValue = "Trash requested. Use Edit → Undo to restore. Rescan to update the map."
    }
}

final class DiskTreemapView: NSView {
    var items: [(Int, String, Int64)] = [] {
        didSet {
            itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.0, $0.offset) })
            kinds = [:]; layoutBounds = nil; needsDisplay = true
            updatePlaceholder()
        }
    }
    /// The ids among `items` that are folders (the rest are files, colored by their kind).
    var folders: Set<Int> = [] { didSet { kinds = [:]; needsDisplay = true } }
    /// Each tile's kind, worked out once (a type lookup per tile per frame adds up on a big map).
    private var kinds: [Int: Kind] = [:]
    private func kind(of id: Int, name: String) -> Kind {
        if let k = kinds[id] { return k }
        let k = Kind(name: name, folder: folders.contains(id)); kinds[id] = k; return k
    }
    private var itemIndices: [Int: Int] = [:]
    private var layoutBounds: CGRect?
    private(set) var layoutCount = 0
    var activate: ((Int) -> Void)?
    private var tiles: [UsageTreemap.Tile] = []
    /// Centred over the map while it has no tiles (DESIGN-CONTRACT E1).
    var placeholder: ListState? { didSet { updatePlaceholder() } }
    let emptyState = ListStateView()
    override var isFlipped: Bool { true }

    private func updatePlaceholder() { emptyState.show(items.isEmpty || items.allSatisfy { $0.2 <= 0 } ? placeholder : nil) }

    /// What a tile holds, for its color: one soft hue per kind, so the map reads at a glance (as DaisyDisk's does)
    /// instead of an arbitrary color per tile.
    enum Kind: CaseIterable {
        case folder, image, video, audio, archive, document, other

        init(name: String, folder: Bool) {
            if folder { self = .folder; return }
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { self = .other; return }
            if type.conforms(to: .image) {
                self = .image
            } else if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) {
                self = .video
            } else if type.conforms(to: .audio) {
                self = .audio
            } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
                self = .archive
            } else if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .content)
            {
                self = .document
            } else {
                self = .other
            }
        }

        /// Mid-tone colors that keep white labels at 4.78:1 or more in both looks, the cushion's lit top included.
        var color: NSColor {
            switch self {
            case .folder: NSColor(srgbRed: 0.205, green: 0.385, blue: 0.615, alpha: 1)
            case .image: NSColor(srgbRed: 0.426, green: 0.303, blue: 0.615, alpha: 1)
            case .video: NSColor(srgbRed: 0.615, green: 0.254, blue: 0.385, alpha: 1)
            case .audio: NSColor(srgbRed: 0.615, green: 0.312, blue: 0.107, alpha: 1)
            case .archive: NSColor(srgbRed: 0.107, green: 0.41, blue: 0.435, alpha: 1)
            case .document: NSColor(srgbRed: 0.205, green: 0.426, blue: 0.238, alpha: 1)
            case .other: NSColor(srgbRed: 0.353, green: 0.369, blue: 0.402, alpha: 1)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        if layoutBounds != bounds {
            tiles = UsageTreemap.layout(items.map { ($0.0, $0.2) }, in: bounds.insetBy(dx: 2, dy: 2))
            layoutBounds = bounds; layoutCount += 1
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Tokens.FontSize.body, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style,
            .shadow: shadow,
        ]
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Tokens.FontSize.small), .foregroundColor: NSColor.white.withAlphaComponent(0.88), .paragraphStyle: style,
            .shadow: shadow,
        ]
        for tile in tiles {
            let rect = tile.rect.insetBy(dx: 1, dy: 1)
            guard rect.intersects(dirtyRect), let index = itemIndices[tile.id] else { continue }
            let item = items[index]
            let path = NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.small, yRadius: Tokens.Radius.small)
            kind(of: tile.id, name: item.1).color.setFill()
            path.fill()
            // A soft cushion: lighter at the top, a little darker at the bottom, so tiles read as objects.
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.black.withAlphaComponent(0.12)])?.draw(in: path, angle: 90)
            guard rect.width > 64, rect.height > 22 else { continue }
            let inner = rect.insetBy(dx: 8, dy: 6)
            (item.1 as NSString).draw(in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 17), withAttributes: nameAttrs)
            if rect.height > 40 {
                (FileFormat.size(item.2) as NSString).draw(
                    in: CGRect(x: inner.minX, y: inner.minY + 18, width: inner.width, height: 15), withAttributes: sizeAttrs)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tile = tiles.first(where: { $0.rect.contains(point) }) { activate?(tile.id) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); setAccessibilityLabel("Disk usage treemap. Use the file list for keyboard navigation.")
        emptyState.frame = bounds
        emptyState.autoresizingMask = [.width, .height]
        addSubview(emptyState)
        emptyState.show(nil)
    }
}
