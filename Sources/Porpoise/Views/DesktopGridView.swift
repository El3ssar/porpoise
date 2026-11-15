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
    private var dragKey: URL?
    private var targetSlot: Int?

    override init(model: DirectoryModel) {
        super.init(model: model)
        unregisterDraggedTypes()
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
        dragKey = nil
        targetSlot = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if rubberStart != nil { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let key = mouseDownURL, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        hoverIndex = nil
        dragKey = key
        targetSlot = visibleRect.contains(point) ? geometry.slot(at: point) : nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragKey = nil; targetSlot = nil; needsDisplay = true }
        if let key = dragKey {
            if let index = model.index(of: key), visibleRect.contains(convert(event.locationInWindow, from: nil)) {
                moveItem(at: index, to: convert(event.locationInWindow, from: nil))
            }
            mouseDownURL = nil
            return
        }
        super.mouseUp(with: event)
    }

    func moveItem(at index: Int, to point: NSPoint) {
        guard itemKeys.indices.contains(index), slots.count == itemKeys.count, let target = geometry.slot(at: point) else { return }
        let source = slots[index]
        guard source != target else { return }
        var positions = Dictionary(uniqueKeysWithValues: zip(itemKeys, slots))
        if let occupant = slots.firstIndex(of: target) { positions[itemKeys[occupant]] = source }
        positions[itemKeys[index]] = target
        onRearrange?(positions)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let targetSlot {
            Theme.focus.setStroke()
            let path = NSBezierPath(
                roundedRect: geometry.frame(for: targetSlot).insetBy(dx: 2, dy: 2),
                xRadius: Theme.itemRadius, yRadius: Theme.itemRadius)
            path.lineWidth = 2
            path.stroke()
        }
    }

    func stopPresentation() {
        cancelRename()
        pendingCollapse?.cancel()
        pendingCollapse = nil
        hoverIndex = nil
        hoverFade.stop()
        transitions.navigate()
        dragKey = nil
        targetSlot = nil
    }
}
