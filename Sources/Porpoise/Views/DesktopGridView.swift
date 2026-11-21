import AppKit
import PorpoiseCore
import PorpoiseServices

enum DesktopGridCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomRight: "Bottom Right"
        case .bottomLeft: "Bottom Left"
        }
    }

    var startsOnRight: Bool { self == .topRight || self == .bottomRight }
    var startsAtBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

/// Only presentation state. Neither enabling Desktop Mode nor file metadata is persisted here.
struct DesktopGridPreferences: Codable {
    static let key = "desktopGridLayout"
    var corner: DesktopGridCorner = .topLeft
    var positions: [String: [String: Int]] = [:]
    var viewProperties: ViewProperties?

    static func load(from store: UserDefaults) -> Self {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(to store: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: Self.key) }
    }
}

/// Slots are integers measured from the chosen corner, filled in columns. Resizing never creates overlapping cells.
struct DesktopGridGeometry {
    let viewport: NSSize
    let corner: DesktopGridCorner
    let cell: NSSize
    let columns: Int
    let rows: Int
    let contentSize: NSSize
    static let inset: CGFloat = 12
    let inset: CGFloat

    init(viewport: NSSize, count: Int, corner: DesktopGridCorner, cellSize: NSSize, inset: CGFloat = Self.inset) {
        self.viewport = viewport
        self.corner = corner
        self.inset = inset
        cell = cellSize
        columns = max(1, Int(max(0, viewport.width - 2 * inset) / cell.width))
        rows = max(1, Int(max(0, viewport.height - 2 * inset) / cell.height), (count + columns - 1) / columns)
        contentSize = NSSize(
            width: max(viewport.width, cell.width + 2 * inset),
            height: max(viewport.height, CGFloat(rows) * cell.height + 2 * inset))
    }

    var capacity: Int { columns * rows }

    func frame(for slot: Int) -> NSRect {
        let column = slot / rows, row = slot % rows
        let x =
            corner.startsOnRight
            ? contentSize.width - inset - CGFloat(column + 1) * cell.width : inset + CGFloat(column) * cell.width
        let y =
            corner.startsAtBottom
            ? contentSize.height - inset - CGFloat(row + 1) * cell.height : inset + CGFloat(row) * cell.height
        return NSRect(origin: NSPoint(x: x, y: y), size: cell)
    }

    func slot(at point: NSPoint) -> Int? {
        guard NSRect(origin: .zero, size: contentSize).contains(point) else { return nil }
        let x = corner.startsOnRight ? contentSize.width - point.x : point.x
        let y = corner.startsAtBottom ? contentSize.height - point.y : point.y
        let column = min(columns - 1, max(0, Int((x - inset) / cell.width)))
        let row = min(rows - 1, max(0, Int((y - inset) / cell.height)))
        return column * rows + row
    }

    func slots(count: Int, preferred: [Int: Int]) -> [Int] {
        var result = [Int](repeating: -1, count: count), used = Set<Int>()
        for index in 0..<count {
            if let slot = preferred[index], slot >= 0, slot < capacity, used.insert(slot).inserted { result[index] = slot }
        }
        var next = 0
        for index in 0..<count where result[index] == -1 {
            while used.contains(next) { next += 1 }
            result[index] = next
            used.insert(next)
        }
        return result
    }
}

/// Placement only; drawing, labels, hover, selection, accessibility and transitions belong to ItemListView.
final class DesktopGridView: ItemListView {
    var scope = ""
    var corner = DesktopGridCorner.topLeft
    var preferred: [Int: Int] = [:]
    private(set) var slots: [Int] = []
    private(set) var geometry = DesktopGridGeometry(viewport: .zero, count: 0, corner: .topLeft, cellSize: NSSize(width: 112, height: 120))
    var onRearrange: (([String: Int]) -> Void)?
    var scrollToCornerAfterLayout = true
    var onDesktop = false {
        didSet { drawsBackground = !onDesktop; tracksWithoutKeyWindow = onDesktop; updateTrackingAreas() }
    }
    override init(model: DirectoryModel) {
        super.init(model: model)
        iconsLayout = { [weak self] in self?.placeItems() ?? .zero }
    }

    required init?(coder: NSCoder) { fatalError() }
    var itemKeys: [String] { model.rows.map { $0.item.url.absoluteString } }
    var isAnimating: Bool { transitionAnimator.isRunning }

    private func placeItems() -> NSSize {
        geometry = DesktopGridGeometry(
            viewport: NSSize(width: visibleWidth, height: visibleHeight), count: model.rows.count,
            corner: corner, cellSize: iconsCellSize, inset: ItemListView.margin)
        slots = geometry.slots(count: model.rows.count, preferred: preferred)
        frames = ItemCellFrames(count: model.rows.count, materialized: slots.map { geometry.frame(for: $0) })
        columns = geometry.columns
        rowsPerColumn = geometry.rows
        return geometry.contentSize
    }

    override func layout() {
        super.layout()
        let viewport = NSSize(width: visibleWidth, height: visibleHeight)
        if viewport != geometry.viewport { transitions.change(.reflow, pictures: false) { relayout() } }
        if scrollToCornerAfterLayout, visibleHeight > 0 {
            scrollToCornerAfterLayout = false
            scroll(NSPoint(x: 0, y: corner.startsAtBottom ? max(0, geometry.contentSize.height - visibleHeight) : 0))
        }
    }

    // The desktop stays in place after opening: rapid double-clicks can continue with counts 4, 6, …
    override func isOpeningClick(_ event: NSEvent) -> Bool { event.clickCount > 0 && event.clickCount.isMultiple(of: 2) }
    override var needsPanelToBecomeKey: Bool { onDesktop }

    override func mouseDown(with event: NSEvent) {
        if onDesktop { window?.makeKey() }
        super.mouseDown(with: event)
    }

    /// Only a drop back onto desktop space rearranges cells. Folders and external files use the browser's target.
    private func rearrangementPoint(_ sender: NSDraggingInfo) -> NSPoint? {
        guard let source = sender.draggingSource as? DesktopGridView, source.model === model else { return nil }
        let operation = DropTargetPolicy.operation(for: sender)
        guard operation == .generic || operation == .move else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let urls = DropTargetPolicy.urls(sender)
        guard visibleRect.contains(point), geometry.slot(at: point) != nil, dropFolder(at: point).1 == nil,
            !urls.isEmpty, urls.allSatisfy({ model.index(of: $0) != nil })
        else { return nil }
        return point
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if rearrangementPoint(sender) != nil {
            setDropTarget(nil, background: true)
            return .move
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let point = rearrangementPoint(sender) else { return super.performDragOperation(sender) }
        let urls = DropTargetPolicy.urls(sender)
        setDropTarget(nil, background: false)
        DropTargetPolicy.dragEnded()
        moveItems(urls, to: point)
        return true
    }

    func moveItem(at index: Int, to point: NSPoint) {
        guard model.rows.indices.contains(index) else { return }
        moveItems([model.rows[index].item.url], to: point)
    }

    private func moveItems(_ urls: [URL], to point: NSPoint) {
        let keys = Set(urls.compactMap { model.index(of: $0).map { model.rows[$0].item.url.absoluteString } })
        let moving = itemKeys.filter(keys.contains)
        guard !moving.isEmpty, slots.count == itemKeys.count, let target = geometry.slot(at: point) else { return }
        var positions = Dictionary(uniqueKeysWithValues: zip(itemKeys, slots))
        let original = positions
        let start = min(target, geometry.capacity - moving.count)
        let destinations = Array(start..<(start + moving.count))
        let occupied = Set(destinations)
        let sources = Set(moving.compactMap { positions[$0] })
        let vacated = sources.subtracting(occupied).sorted()
        let displaced = zip(itemKeys, slots).filter { !keys.contains($0.0) && occupied.contains($0.1) }.map(\.0)
        for (key, slot) in zip(displaced, vacated) { positions[key] = slot }
        for (key, slot) in zip(moving, destinations) { positions[key] = slot }
        guard positions != original else { return }
        onRearrange?(positions)
    }

    func stopPresentation() {
        cancelRename()
        pendingCollapse?.cancel()
        pendingCollapse = nil
        hoverIndex = nil
        hoverFade.stop()
        transitions.navigate()
        setDropTarget(nil, background: false)
    }
}
