import AppKit
import PorpoiseCore
import PorpoiseServices

final class DiskUsageWindow: DiskUtilityWindow {
    private let roots: [URL]
    private var tree: UsageTree?
    private var current = 0
    private var children: [Int] = []
    private var allocated = false
    private let map = DiskTreemapView()
    init(roots: [URL]) {
        self.roots = roots
        super.init(
            title: "Disk Usage",
            columns: [("name", "Name", 360), ("logical", "Logical size", 150), ("allocated", "Allocated size", 150), ("files", "Unique files", 100)],
            sortable: true)
        window?.setContentSize(NSSize(width: 1000, height: 740)); window?.minSize.height = 720; window?.center()
        toolbar.addArrangedSubview(ClosureButton(title: "Back") { [weak self] _ in self?.back() })
        toolbar.addArrangedSubview(ClosureButton(title: "Rescan") { [weak self] _ in self?.scan() })
        toolbar.addArrangedSubview(ClosureButton(title: "Reveal in Finder") { [weak self] _ in self?.reveal() })
        toolbar.addArrangedSubview(ClosureButton(title: "Move to Trash") { [weak self] _ in self?.trash() })
        let metric = ClosurePopup { [weak self] p in
            self?.allocated = p.indexOfSelectedItem == 1; self?.reload()
        }
        metric.addItems(withTitles: ["Map logical bytes", "Map allocated bytes"]); toolbar.addArrangedSubview(metric)
        stack.insertArrangedSubview(map, at: 1)
        map.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; map.heightAnchor.constraint(equalToConstant: 200).isActive = true
        map.activate = { [weak self] id in self?.enter(id) }
        table.target = self; table.doubleAction = #selector(openRow)
        note(
            "Double-click a directory or click its map tile to drill down. Hard links count once across the selection. Allocated bytes exclude directory metadata and may overlap across APFS clones; they are not guaranteed reclaimable space. Scans stay on selected volumes."
        )
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
        map.items = children.map { id in (id, tree.nodes[id].name, allocated ? tree.nodes[id].allocated : tree.nodes[id].logical) }
        let node = tree.nodes[current]
        status.stringValue =
            "\(node.url?.path ?? "Selection") · \(FileFormat.size(node.logical)) logical · \(FileFormat.size(node.allocated)) allocated · \(node.files.formatted()) unique files · \(tree.hardLinkAliases) hard-link aliases · \(errors.count) errors"
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
    private var selectedURL: URL? {
        guard children.indices.contains(table.selectedRow), let tree else { return nil }; return tree.nodes[children[table.selectedRow]].url
    }
    private func reveal() { if let url = selectedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    private func trash() {
        guard !busy, let url = selectedURL else { return }
        FileOperationsController.shared.trash([url], window: window)
        FolderUsageCache.shared.invalidate(below: url.deletingLastPathComponent())
        status.stringValue = "Trash requested. Use Edit → Undo to restore. Rescan to update the map."
    }
}

private final class DiskTreemapView: NSView {
    var items: [(Int, String, Int64)] = [] { didSet { needsDisplay = true } }
    var activate: ((Int) -> Void)?
    private var tiles: [UsageTreemap.Tile] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        tiles = UsageTreemap.layout(items.map { ($0.0, $0.2) }, in: bounds.insetBy(dx: 2, dy: 2))
        for (i, tile) in tiles.enumerated() {
            let rect = tile.rect.insetBy(dx: 1, dy: 1)
            NSColor(calibratedHue: CGFloat((i * 37) % 100) / 100, saturation: 0.48, brightness: 0.65, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            if rect.width > 65 && rect.height > 32, let item = items.first(where: { $0.0 == tile.id }) {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
                let text = item.1 + "\n" + FileFormat.size(item.2)
                (text as NSString).draw(
                    in: rect.insetBy(dx: 6, dy: 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white, .paragraphStyle: style])
            }
        }
        if tiles.isEmpty {
            ("No non-zero files in this level" as NSString).draw(
                at: CGPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tile = tiles.first(where: { $0.rect.contains(point) }) { activate?(tile.id) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); setAccessibilityLabel("Disk usage treemap. Use the file list for keyboard navigation.")
    }
}
