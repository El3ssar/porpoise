import AppKit
import PorpoiseCore
import PorpoiseServices

protocol PlacesPanelDelegate: AnyObject {
    func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool)
    func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL)
    func places(_ p: PlacesPanel, emptyTrash: Void)
    func places(_ p: PlacesPanel, properties url: URL)
    func placesWantsViewFocus(_ p: PlacesPanel)
}

/// Dolphin's Places panel, custom-drawn (section headers, icon rows, capacity bars for devices).
final class PlacesPanel: NSView {
    weak var delegate: PlacesPanelDelegate?
    var currentURL: URL? { didSet { needsDisplay = true } }

    enum Metrics {
        static let topInset: CGFloat = 4
        static let headerHeight: CGFloat = 26
        static let sectionGap: CGFloat = 8
        /// Device rows are taller to fit the capacity bar.
        static let volumeExtraHeight: CGFloat = 8
        static let minRowHeight: CGFloat = 28
        static let iconX: CGFloat = 18
        static let iconTextGap: CGFloat = 8
        static let pillInset: CGFloat = 8
        static let pillRadius: CGFloat = 6
        static let ejectIconSize: CGFloat = 16
        /// Eject icon's left edge, from the row's right edge.
        static let ejectIconRightOffset: CGFloat = 34
        /// Clicks this close to the right edge of an ejectable row hit the eject button.
        static let ejectHitWidth: CGFloat = 40
        static let ejectTextReserve: CGFloat = 24
        /// A click that wobbles less than this is still a click, not a drag.
        static let dragThreshold: CGFloat = 5
        /// Dropping folders this close to a row edge inserts a new place instead of dropping onto the row.
        static let dropEdge: CGFloat = 6
        static let dragImageMaxWidth: CGFloat = 220
    }

    enum RowKind { case header(PlaceSection), entry(PlaceEntry) }
    struct Row { let kind: RowKind; let y: CGFloat; let height: CGFloat }
    struct VolumeCapacity { let free: Int64; let total: Int64 }

    var rows: [Row] = []

    // Fold/unfold animation (macOS style): rows glide to their new places, folding rows slide into their header and
    // fade, unfolding ones come out of it; the chevron turns.
    private let foldAnimator = Animator()
    var foldProgress: CGFloat = 1
    /// Per row of `rows`: where it starts (offset from its final y) and its starting opacity.
    private var foldStartOffset: [CGFloat] = []
    private var foldStartAlpha: [CGFloat] = []
    /// Rows that disappear (a folding section): drawn sliding from `fromY` to `toY` while fading out.
    var foldGhosts: [(row: Row, fromY: CGFloat, toY: CGFloat)] = []
    /// Section whose chevron turns, and whether it is folding.
    var foldSection: (sec: PlaceSection, folding: Bool)?
    /// Set before a fold toggle so the next reload animates.
    var animateNextReload = false

    private static func rowKey(_ k: RowKind) -> String {
        switch k {
        case .header(let s): return "h|" + s.rawValue
        case .entry(let e): return "e|\(e.section.rawValue)|\(e.title)|\(e.url.absoluteString)"
        }
    }

    /// Folds or unfolds a section with the animation.
    func toggleSectionAnimated(_ sec: PlaceSection) {
        foldSection = (sec, !PlacesModel.shared.collapsedSections.contains(sec))
        animateNextReload = true
        PlacesModel.shared.toggleCollapsed(sec)
    }

    private func prepareFoldAnimation(old: [Row], new: [Row]) {
        var oldY: [String: CGFloat] = [:]
        for r in old { oldY[Self.rowKey(r.kind)] = r.y }
        var newHeaderY: [String: CGFloat] = [:]
        for r in new { if case .header(let s) = r.kind { newHeaderY[s.rawValue] = r.y } }
        let newKeys = Set(new.map { Self.rowKey($0.kind) })
        // A section's rows move as one block (a drawer sliding under its header), by the block's height.
        func blockHeight(_ list: [Row], _ sec: String) -> CGFloat {
            list.reduce(0) { sum, r in
                if case .entry(let e) = r.kind, e.section.rawValue == sec { return sum + r.height } else { return sum }
            }
        }
        foldStartOffset = new.map { r in
            if let y = oldY[Self.rowKey(r.kind)] { return y - r.y }
            // Appearing (unfolding): starts tucked under its header.
            if case .entry(let e) = r.kind { return -blockHeight(new, e.section.rawValue) }
            return 0
        }
        foldStartAlpha = new.map { oldY[Self.rowKey($0.kind)] != nil ? 1 : 0 }
        // Folding rows slide up until they're hidden under their header (they're clipped below it while drawn).
        foldGhosts = old.compactMap { r in
            guard !newKeys.contains(Self.rowKey(r.kind)), case .entry(let e) = r.kind, let hy = newHeaderY[e.section.rawValue],
                  let oldHy = oldY["h|" + e.section.rawValue] else { return nil }
            // Same place relative to its header, then up by the block height.
            let start = hy + (r.y - oldHy)
            return (r, r.y, start - blockHeight(old, e.section.rawValue))
        }
        foldProgress = 0
        foldAnimator.run(duration: 0.24, curve: Animator.easeOutCubic, step: { [weak self] p in
            self?.foldProgress = CGFloat(p)
            self?.needsDisplay = true
        }, completion: { [weak self] in
            guard let self else { return }
            self.foldProgress = 1
            self.foldStartOffset = []
            self.foldStartAlpha = []
            self.foldGhosts = []
            self.foldSection = nil
            self.needsDisplay = true
        })
    }

    func animatedAlpha(_ i: Int) -> CGFloat {
        guard i < foldStartAlpha.count else { return 1 }
        return foldStartAlpha[i] + (1 - foldStartAlpha[i]) * foldProgress
    }
    var hover: Int?
    var pressed: Int?
    var pressPoint: CGPoint = .zero
    var isDraggingRow = false
    /// Row receiving a file drop.
    var dropIndex: Int?
    /// Row index a new or moved place would be inserted before (may be a header or `rows.count`).
    var dropInsertBefore: Int?
    /// `allFolders` result for the current drag (dragging updates arrive continuously).
    var dragFolderCheck: (sequence: Int, allFolders: Bool)?
    var tracking: NSTrackingArea?

    /// Volume capacities, refreshed off the main thread (they can be slow, or hang on network volumes).
    var capacities: [URL: VolumeCapacity] = [:]
    var capacityQueryRunning = false
    var capacityQueryPending = false
    static let capacityQueue = DispatchQueue(label: "porpoise.places.capacity", qos: .utility)

    var trashState: (modified: Date, full: Bool)?
    var ejecting: Set<URL> = []

    /// Header under the pointer (for its fold chevron).
    var headerHover: Int?

    /// Section being dropped before (nil = at the end), from the pointer: the upper half of a section's block
    /// (header plus its rows) drops before it, the lower half before the next one.
    var sectionDrop: PlaceSection?

    /// Where a dragged section would land (the insertion line's y).
    var sectionInsertY: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .placeEntry, .placeSection])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: PlacesModel.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: Settings.changed, object: nil)
        reload()
        setAccessibilityRole(.list)
        setAccessibilityLabel("Places")
    }

    required init?(coder: NSCoder) { fatalError() }

    var rowHeight: CGFloat { max(Metrics.minRowHeight, CGFloat(Settings.shared.placesIconSize) + 12) }

    @objc private func settingsChanged(_ n: Notification) {
        // Only the icon size (or a full reset) changes this panel.
        let key = n.object as? String
        if key == nil || key == "placesIcon" { reload() }
    }

    /// The frame height must cover every row, or rows past it draw but can't be clicked. Size it whenever the
    /// panel is placed into (or moved within) a scroll view, not only when the places change.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { reload() }
    }

    /// Always exactly as wide as the visible sidebar (eject buttons sit at the right edge) and tall enough for every row.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let clip = enclosingScrollView?.contentView.bounds.size else { return super.resize(withOldSuperviewSize: oldSize) }
        let needed = (rows.last.map { $0.y + $0.height } ?? 0) + Metrics.sectionGap
        let size = NSSize(width: clip.width, height: max(needed, clip.height))
        if frame.size != size { setFrameSize(size) }
    }

    @objc func reload() {
        var y = Metrics.topInset
        var out: [Row] = []
        for (sec, entries) in PlacesModel.shared.sections() {
            out.append(Row(kind: .header(sec), y: y, height: Metrics.headerHeight))
            y += Metrics.headerHeight
            for e in entries where !PlacesModel.shared.collapsedSections.contains(sec) {
                let h = e.isVolume ? rowHeight + Metrics.volumeExtraHeight : rowHeight
                out.append(Row(kind: .entry(e), y: y, height: h))
                y += h
            }
            y += Metrics.sectionGap
        }
        if animateNextReload, window != nil, !rows.isEmpty {
            animateNextReload = false
            prepareFoldAnimation(old: rows, new: out)
        } else {
            animateNextReload = false
            foldAnimator.stop()
            foldProgress = 1
            foldStartOffset = []
            foldStartAlpha = []
            foldGhosts = []
        }
        rows = out
        // Row indices changed: drop stale hover/press state.
        pressed = nil
        hover = nil
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(p) { hover = hoverIndex(at: p) }
        }
        let clip = enclosingScrollView?.contentView.bounds
        setFrameSize(NSSize(width: clip?.width ?? bounds.width, height: max(y, clip?.height ?? 0)))
        refreshCapacities()
        needsDisplay = true
    }

    // MARK: Rows

    /// Row frame of the place with this title (tests).
    func rowRect(title: String) -> CGRect? {
        rows.indices.first {
            switch rows[$0].kind {
            case .entry(let e): return e.title == title
            case .header(let s): return "section:" + s.rawValue == title
            }
        }.map(rect(of:))
    }

    func rect(of i: Int) -> CGRect {
        let offset = i < foldStartOffset.count ? foldStartOffset[i] * (1 - foldProgress) : 0
        return CGRect(x: 0, y: rows[i].y + offset, width: bounds.width, height: rows[i].height)
    }

    func rowIndex(at p: CGPoint) -> Int? { rows.firstIndex { p.y >= $0.y && p.y < $0.y + $0.height } }

    func entry(at i: Int?) -> PlaceEntry? {
        guard let i, rows.indices.contains(i), case .entry(let e) = rows[i].kind else { return nil }
        return e
    }

    func hoverIndex(at p: CGPoint) -> Int? {
        let i = rowIndex(at: p)
        return entry(at: i) != nil ? i : nil
    }

    var entryIndices: [Int] { rows.indices.filter { entry(at: $0) != nil } }

    func isCurrent(_ e: PlaceEntry) -> Bool {
        guard let c = currentURL else { return false }
        return e.url.standardizedFileURL == c.standardizedFileURL
    }
}
