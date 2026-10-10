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

    private enum Metrics {
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

    private enum RowKind { case header(PlaceSection), entry(PlaceEntry) }
    private struct Row { let kind: RowKind; let y: CGFloat; let height: CGFloat }
    private struct VolumeCapacity { let free: Int64; let total: Int64 }

    private var rows: [Row] = []

    // Fold/unfold animation (macOS style): rows glide to their new places, folding rows slide into their header and
    // fade, unfolding ones come out of it; the chevron turns.
    private let foldAnimator = Animator()
    private var foldProgress: CGFloat = 1
    /// Per row of `rows`: where it starts (offset from its final y) and its starting opacity.
    private var foldStartOffset: [CGFloat] = []
    private var foldStartAlpha: [CGFloat] = []
    /// Rows that disappear (a folding section): drawn sliding from `fromY` to `toY` while fading out.
    private var foldGhosts: [(row: Row, fromY: CGFloat, toY: CGFloat)] = []
    /// Section whose chevron turns, and whether it is folding.
    private var foldSection: (sec: PlaceSection, folding: Bool)?
    /// Set before a fold toggle so the next reload animates.
    private var animateNextReload = false

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

    private func animatedAlpha(_ i: Int) -> CGFloat {
        guard i < foldStartAlpha.count else { return 1 }
        return foldStartAlpha[i] + (1 - foldStartAlpha[i]) * foldProgress
    }
    private var hover: Int?
    private var pressed: Int?
    private var pressPoint: CGPoint = .zero
    private var isDraggingRow = false
    /// Row receiving a file drop.
    private var dropIndex: Int?
    /// Row index a new or moved place would be inserted before (may be a header or `rows.count`).
    private var dropInsertBefore: Int?
    /// `allFolders` result for the current drag (dragging updates arrive continuously).
    private var dragFolderCheck: (sequence: Int, allFolders: Bool)?
    private var tracking: NSTrackingArea?

    /// Volume capacities, refreshed off the main thread (they can be slow, or hang on network volumes).
    private var capacities: [URL: VolumeCapacity] = [:]
    private var capacityQueryRunning = false
    private var capacityQueryPending = false
    private static let capacityQueue = DispatchQueue(label: "porpoise.places.capacity", qos: .utility)

    private var trashState: (modified: Date, full: Bool)?
    private var ejecting: Set<URL> = []

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

    private var rowHeight: CGFloat { max(Metrics.minRowHeight, CGFloat(Settings.shared.placesIconSize) + 12) }

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

    private func rect(of i: Int) -> CGRect {
        let offset = i < foldStartOffset.count ? foldStartOffset[i] * (1 - foldProgress) : 0
        return CGRect(x: 0, y: rows[i].y + offset, width: bounds.width, height: rows[i].height)
    }

    private func rowIndex(at p: CGPoint) -> Int? { rows.firstIndex { p.y >= $0.y && p.y < $0.y + $0.height } }

    private func entry(at i: Int?) -> PlaceEntry? {
        guard let i, rows.indices.contains(i), case .entry(let e) = rows[i].kind else { return nil }
        return e
    }

    private func hoverIndex(at p: CGPoint) -> Int? {
        let i = rowIndex(at: p)
        return entry(at: i) != nil ? i : nil
    }

    private var entryIndices: [Int] { rows.indices.filter { entry(at: $0) != nil } }

    private func isCurrent(_ e: PlaceEntry) -> Bool {
        guard let c = currentURL else { return false }
        return e.url.standardizedFileURL == c.standardizedFileURL
    }

    // MARK: Capacity and trash state

    private func refreshCapacities() {
        guard !capacityQueryRunning else { capacityQueryPending = true; return }
        let volumes = rows.compactMap { row -> URL? in
            if case .entry(let e) = row.kind, e.isVolume { return e.url } else { return nil }
        }
        guard !volumes.isEmpty else { capacities = [:]; return }
        capacityQueryRunning = true
        Self.capacityQueue.async { [weak self] in
            var result: [URL: VolumeCapacity] = [:]
            for u in volumes {
                guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
                      let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { continue }
                result[u] = VolumeCapacity(free: free, total: Int64(total))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.capacities = result
                self.capacityQueryRunning = false
                self.needsDisplay = true
                if self.capacityQueryPending { self.capacityQueryPending = false; self.refreshCapacities() }
            }
        }
    }

    /// Re-lists the Trash only when its modification date changes (this runs while drawing).
    private func trashIsFull() -> Bool {
        let path = TrashInfo.folder.path
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        if let s = trashState, s.modified == modified { return s.full }
        let full = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).contains { $0 != ".DS_Store" }
        trashState = (modified, full)
        return full
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        // While a section folds or unfolds, its rows are only visible below its (moving) header.
        var clipTop: CGFloat?
        if let f = foldSection, foldProgress < 1, let h = rows.indices.first(where: { header(at: $0) == f.sec }) { clipTop = rect(of: h).maxY }
        let belowHeader = { (top: CGFloat) in CGRect(x: 0, y: top, width: self.bounds.width, height: max(0, self.bounds.height - top)) }
        // Folding rows first, so the rows below draw over them as they slide in.
        for g in foldGhosts {
            guard case .entry(let e) = g.row.kind else { continue }
            let y = g.fromY + (g.toY - g.fromY) * foldProgress
            ctx?.saveGState()
            if let top = clipTop { ctx?.clip(to: belowHeader(top)) }
            ctx?.setAlpha(1 - foldProgress)
            drawEntry(e, index: -1, in: CGRect(x: 0, y: y, width: bounds.width, height: g.row.height))
            ctx?.restoreGState()
        }
        for i in rows.indices {
            let r = rect(of: i)
            guard r.intersects(dirty) else { continue }
            let a = animatedAlpha(i)
            let clipped: Bool = {
                guard let top = clipTop, let f = foldSection, case .entry(let e) = rows[i].kind else { return false }
                return e.section == f.sec && r.minY < top
            }()
            if a < 1 || clipped {
                ctx?.saveGState()
                if a < 1 { ctx?.setAlpha(a) }
                if clipped, let top = clipTop { ctx?.clip(to: belowHeader(top)) }
            }
            switch rows[i].kind {
            case .header(let sec): drawHeader(sec, index: i, in: r)
            case .entry(let e): drawEntry(e, index: i, in: r)
            }
            if a < 1 || clipped { ctx?.restoreGState() }
        }
        drawInsertionMarker()
    }

    /// Finder-style section header: small, semibold, secondary color.
    private func drawHeader(_ sec: PlaceSection, index i: Int, in r: CGRect) {
        let hovered = headerHover == i
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: Theme.windowTextInactive.withAlphaComponent(hovered ? 0.85 : 0.62)]
        (sec.rawValue as NSString).draw(at: CGPoint(x: Metrics.iconX, y: r.minY + 9), withAttributes: attrs)
        // Fold chevron (Finder shows it on hover; folded sections always show theirs).
        let collapsed = PlacesModel.shared.collapsedSections.contains(sec)
        let turning = foldSection?.sec == sec && foldProgress < 1
        guard hovered || collapsed || turning, let img = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) else { return }
        let conf = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [Theme.windowTextInactive.withAlphaComponent(hovered ? 0.85 : 0.5)]))
        let c = img.withSymbolConfiguration(conf) ?? img
        // Pointing right when folded, down when open; turning in between while animating.
        var open: CGFloat = collapsed ? 0 : 1
        if turning, let f = foldSection { open = f.folding ? 1 - foldProgress : foldProgress }
        let box = CGRect(x: r.maxX - 26, y: r.minY + 8, width: 12, height: 12)
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: box.midX, yBy: box.midY)
        t.rotate(byDegrees: 90 * open)
        t.concat()
        c.draw(in: CGRect(x: -c.size.width / 2, y: -c.size.height / 2, width: c.size.width, height: c.size.height), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEntry(_ e: PlaceEntry, index i: Int, in r: CGRect) {
        let current = isCurrent(e)
        drawBackground(current: current, index: i, in: r)
        let iconSize = CGFloat(Settings.shared.placesIconSize)
        let alpha: CGFloat = e.hidden ? 0.45 : 1
        let iy = e.isVolume ? r.minY + (rowHeight - iconSize) / 2 + 1 : r.midY - iconSize / 2
        let iconRect = CGRect(x: Metrics.iconX, y: iy, width: iconSize, height: iconSize)
        if e.section == .tags, let c = FinderTags.standard.first(where: { $0.name == e.title }).flatMap({ FinderTags.color($0.color) }) {
            c.setFill()
            NSBezierPath(ovalIn: iconRect.insetBy(dx: iconSize * 0.2, dy: iconSize * 0.2)).fill()
        } else {
            let name = e.icon == "user-trash" && trashIsFull() ? "user-trash-full" : e.icon
            Icons.shared.image(name, size: iconSize, selected: current)?
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }

        let tx = Metrics.iconX + iconSize + Metrics.iconTextGap
        let ejectW: CGFloat = e.isEjectable ? Metrics.ejectTextReserve : 0
        let lh = Theme.font.ascender - Theme.font.descender
        let ty = e.isVolume ? r.minY + (rowHeight - lh) / 2 - 1 : r.midY - lh / 2 - 1
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.windowText.withAlphaComponent(alpha), .paragraphStyle: p]
        let title = e.hidden ? e.title + " (hidden)" : e.title
        (title as NSString).draw(in: CGRect(x: tx, y: ty, width: r.width - tx - 14 - ejectW, height: lh + 3), withAttributes: attrs)

        if e.isVolume, let c = capacities[e.url], c.total > 0 {
            drawCapacityBar(c, in: CGRect(x: tx, y: ty + lh + 4, width: r.width - tx - 16 - ejectW, height: 3))
        }
        if e.isEjectable, let img = Icons.shared.image("media-eject", size: Metrics.ejectIconSize) {
            let s = Metrics.ejectIconSize
            img.draw(in: CGRect(x: r.maxX - Metrics.ejectIconRightOffset, y: r.minY + (rowHeight - s) / 2, width: s, height: s),
                     from: .zero, operation: .sourceOver, fraction: hover == i ? 1 : 0.55, respectFlipped: true, hints: nil)
        }
    }

    /// Rounded, inset highlight like a Mac sidebar: current place, drop target or hover.
    private func drawBackground(current: Bool, index i: Int, in r: CGRect) {
        let fill: NSColor
        if current && hasKeyFocus {
            fill = Theme.selection
        } else if current || dropIndex == i {
            fill = Theme.selection.withAlphaComponent(window?.isKeyWindow == false ? 0.35 : 0.62)
        } else if hover == i {
            fill = Theme.windowText.withAlphaComponent(0.07)
        } else {
            return
        }
        fill.setFill()
        let pill = CGRect(x: Metrics.pillInset, y: r.minY + 1, width: r.width - 2 * Metrics.pillInset, height: r.height - 2)
        NSBezierPath(roundedRect: pill, xRadius: Metrics.pillRadius, yRadius: Metrics.pillRadius).fill()
    }

    /// Capacity bar (KFilePlacesView draws one under device names), slim and rounded.
    private func drawCapacityBar(_ c: VolumeCapacity, in bar: CGRect) {
        Theme.windowText.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        let used = CGFloat(c.total - c.free) / CGFloat(c.total)
        (used > 0.95 ? Theme.negativeText : Theme.selectionAlternate.withAlphaComponent(0.85)).setFill()
        let fill = CGRect(x: bar.minX, y: bar.minY, width: max(3, bar.width * used), height: bar.height)
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// The line where a dragged folder or place would be inserted; also at the end of a section.
    private func drawInsertionMarker() {
        if let sy = sectionInsertY {
            Theme.selectionAlternate.setFill()
            NSBezierPath(roundedRect: CGRect(x: 12, y: sy - 1, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
            return
        }
        guard let ins = dropInsertBefore else { return }
        let y: CGFloat
        if entry(at: ins) != nil { y = rows[ins].y }
        else if entry(at: ins - 1) != nil { y = rows[ins - 1].y + rows[ins - 1].height }
        else if entry(at: ins + 1) != nil { y = rows[ins + 1].y }
        else { return }
        Theme.selectionAlternate.setFill()
        NSBezierPath(roundedRect: CGRect(x: 12, y: y - 1, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    // MARK: Keyboard (Focus Places Panel, ⌘P)

    override var acceptsFirstResponder: Bool { true }
    /// A click on a place in a background window goes there at once (as Finder's sidebar), not only activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    var hasKeyFocus: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    private enum KeyCode {
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, tab: UInt16 = 48, escape: UInt16 = 53
        static let down: UInt16 = 125, up: UInt16 = 126, home: UInt16 = 115, end: UInt16 = 119
    }

    override func keyDown(with event: NSEvent) {
        let idx = entryIndices
        guard !idx.isEmpty else { return super.keyDown(with: event) }
        let cur = idx.firstIndex { i in entry(at: i).map(isCurrent) ?? false }
        func open(_ k: Int) {
            let row = idx[max(0, min(idx.count - 1, k))]
            guard let e = entry(at: row) else { return }
            delegate?.places(self, open: e.url, newTab: false, splitView: false)
            scrollToVisible(rect(of: row).insetBy(dx: 0, dy: -8))
        }
        // The current place may be inside a folded section: step from its position in the full list, so ↓/↑ go to
        // the next/previous shown place instead of jumping to the first/last one.
        var nextAfterFolded: Int?, previousBeforeFolded: Int?
        if cur == nil {
            let all = PlacesModel.shared.sections().flatMap(\.1)
            if let c = all.firstIndex(where: isCurrent) {
                let shown = { (e: PlaceEntry) in idx.firstIndex { self.entry(at: $0) == e } }
                nextAfterFolded = all[(c + 1)...].lazy.compactMap(shown).first ?? idx.count - 1
                previousBeforeFolded = all[..<c].reversed().lazy.compactMap(shown).first ?? 0
            }
        }
        switch event.keyCode {
        case KeyCode.down: open(cur.map { $0 + 1 } ?? nextAfterFolded ?? 0)
        case KeyCode.up: open(cur.map { $0 - 1 } ?? previousBeforeFolded ?? idx.count - 1)
        case KeyCode.home: open(0)
        case KeyCode.end: open(idx.count - 1)
        case KeyCode.returnKey, KeyCode.enter, KeyCode.tab, KeyCode.escape: delegate?.placesWantsViewFocus(self)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let hp = convert(event.locationInWindow, from: nil)
        let hh = rowIndex(at: hp).flatMap { header(at: $0) != nil ? $0 : nil }
        if hh != headerHover { headerHover = hh; needsDisplay = true }
        let h = hoverIndex(at: convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
        let tip = tooltip(for: entry(at: h))
        // Re-setting the same tooltip on every move would restart its delay.
        if tip != toolTip { toolTip = tip }
    }

    private func tooltip(for e: PlaceEntry?) -> String? {
        guard let e else { return nil }
        if e.isVolume, let c = capacities[e.url] {
            let usedPct = c.total > 0 ? Int(Double(c.total - c.free) / Double(c.total) * 100) : 0
            return "\(FileFormat.size(c.free)) free out of \(FileFormat.size(c.total)) (\(usedPct)% used)"
        }
        if e.url.isFileURL { return e.url.path }
        return RemoteFS.isRemote(e.url) || NetworkMounts.needsMount(e.url) ? e.url.absoluteString : nil
    }

    override func mouseExited(with event: NSEvent) {
        if headerHover != nil { headerHover = nil; needsDisplay = true }
        guard hover != nil else { return }
        hover = nil
        needsDisplay = true
    }

    /// Header under the pointer (for its fold chevron).
    private var headerHover: Int?

    private func header(at i: Int?) -> PlaceSection? {
        guard let i, rows.indices.contains(i), case .header(let sec) = rows[i].kind else { return nil }
        return sec
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = rowIndex(at: p)
        pressPoint = p
        isDraggingRow = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !isDraggingRow, !PlacesModel.shared.isLocked, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > Metrics.dragThreshold,
              let i = pressed else { return }
        if let sec = header(at: i) { beginSectionDrag(sec, row: i, event: event); return }
        guard let e = entry(at: i), !e.isVolume else { return }
        isDraggingRow = true
        let item = NSPasteboardItem()
        item.setString(e.title + "\n" + e.url.absoluteString, forType: .placeEntry)
        if e.url.isFileURL { item.setString(e.url.absoluteString, forType: .fileURL) }
        let di = NSDraggingItem(pasteboardWriter: item)
        // Drag image: a picture of the row (icon + name), like dragging a sidebar item in Finder.
        let r = CGRect(x: 0, y: rows[i].y, width: min(bounds.width, Metrics.dragImageMaxWidth), height: rows[i].height)
        let snapshot = NSImage(size: r.size)
        if let rep = bitmapImageRepForCachingDisplay(in: r) {
            cacheDisplay(in: r, to: rep)
            snapshot.addRepresentation(rep)
        }
        di.setDraggingFrame(r, contents: snapshot)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    /// Dragging a section header moves the whole section (unless Places are locked).
    private func beginSectionDrag(_ sec: PlaceSection, row i: Int, event: NSEvent) {
        isDraggingRow = true
        let item = NSPasteboardItem()
        item.setString(sec.rawValue, forType: .placeSection)
        let di = NSDraggingItem(pasteboardWriter: item)
        let end = rows.indices.first { $0 > i && header(at: $0) != nil }.map { rows[$0].y } ?? (rows.last.map { $0.y + $0.height } ?? rows[i].y)
        let r = CGRect(x: 0, y: rows[i].y, width: min(bounds.width, Metrics.dragImageMaxWidth), height: min(max(rows[i].height, end - rows[i].y), 240))
        let snapshot = NSImage(size: r.size)
        if let rep = bitmapImageRepForCachingDisplay(in: r) {
            cacheDisplay(in: r, to: rep)
            snapshot.addRepresentation(rep)
        }
        di.setDraggingFrame(r, contents: snapshot)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { pressed = nil }
        guard !isDraggingRow, let i = rowIndex(at: p), i == pressed else { return }
        if let sec = header(at: i) { toggleSectionAnimated(sec); return }
        guard let e = entry(at: i) else { return }
        if e.isEjectable && p.x > bounds.width - Metrics.ejectHitWidth { eject(e); return }
        delegate?.places(self, open: e.url, newTab: event.modifierFlags.contains(.command), splitView: false)
    }

    /// Middle click opens in a new tab; other buttons (mouse back/forward) go up the responder chain.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if let e = entry(at: rowIndex(at: convert(event.locationInWindow, from: nil))) {
            delegate?.places(self, open: e.url, newTab: true, splitView: false)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let i = rowIndex(at: convert(event.locationInWindow, from: nil))
        func add(_ title: String, _ icon: String?, _ action: Selector, _ obj: Any? = nil) {
            let it = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = obj
            if let icon { it.image = Icons.shared.menuIcon(icon) }
        }
        if let e = entry(at: i) {
            add("Open in New Tab", "tab-new", #selector(openNewTab(_:)), e.url)
            add("Open in New Window", "window-new", #selector(openNewWindow(_:)), e.url)
            add("Open in Split View", "view-split-left-right", #selector(openSplit(_:)), e.url)
            m.addItem(.separator())
            if e.icon == "user-trash" {
                add("Empty Trash", "trash-empty", #selector(emptyTrash))
                m.addItem(.separator())
            }
            if e.isEjectable {
                add("Eject", "media-eject", #selector(ejectMenu(_:)), e)
                m.addItem(.separator())
            }
            // Only bookmarks can be edited; devices, tags and detected cloud folders/phones can't.
            if PlacesModel.shared.isUserEntry(e) {
                add("Edit…", "edit-entry", #selector(editEntry(_:)), e)
                add(e.hidden ? "Show" : "Hide", e.hidden ? "view-visible" : "view-hidden", #selector(toggleHidden(_:)), e)
                add("Remove from Places", "bookmark-remove", #selector(removeEntry(_:)), e)
            }
            if !PlacesModel.shared.hiddenSections.contains(e.section) {
                add("Hide Section “\(e.section.rawValue)”", "view-hidden", #selector(hideSection(_:)), e.section.rawValue)
            }
            m.addItem(.separator())
        } else if let i, case .header(let sec) = rows[i].kind {
            let folded = PlacesModel.shared.collapsedSections.contains(sec)
            add(folded ? "Expand “\(sec.rawValue)”" : "Collapse “\(sec.rawValue)”", nil, #selector(toggleSection(_:)), sec.rawValue)
            if !PlacesModel.shared.isLocked {
                let order = PlacesModel.shared.sections().map(\.0)
                if let n = order.firstIndex(of: sec) {
                    if n > 0 { add("Move Section Up", "go-up", #selector(moveSectionUp(_:)), sec.rawValue) }
                    if n < order.count - 1 { add("Move Section Down", "go-down", #selector(moveSectionDown(_:)), sec.rawValue) }
                }
            }
            // Hidden sections are listed while "Show Hidden Places" is on; they can be shown again one by one.
            if PlacesModel.shared.hiddenSections.contains(sec) {
                add("Show Section “\(sec.rawValue)”", "view-visible", #selector(showSection(_:)), sec.rawValue)
            } else {
                add("Hide Section “\(sec.rawValue)”", "view-hidden", #selector(hideSection(_:)), sec.rawValue)
            }
            m.addItem(.separator())
        }
        let model = PlacesModel.shared
        let anyFolded = !model.collapsedSections.isEmpty
        add(anyFolded ? "Expand All Sections" : "Collapse All Sections", nil, #selector(toggleAllSections))
        let lock = m.addItem(withTitle: "Lock Places", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = model.isLocked ? .on : .off
        lock.toolTip = "Locked: places and sections can't be dragged or reordered."
        m.addItem(.separator())
        add("Add Entry…", "bookmark-new", #selector(addEntry))
        add("Add Network Folder…", "folder-network", #selector(addNetworkFolder))
        let showAll = m.addItem(withTitle: "Show Hidden Places", action: #selector(toggleShowHidden), keyEquivalent: "")
        showAll.target = self
        showAll.state = PlacesModel.shared.showHidden ? .on : .off
        m.addItem(iconSizeMenuItem())
        if !PlacesModel.shared.hiddenSections.isEmpty {
            add("Show All Sections", nil, #selector(showSections))
        }
        add("Reset to Defaults", nil, #selector(resetPlaces))
        if let e = entry(at: i), e.url.isFileURL {
            m.addItem(.separator())
            add("Properties", "document-properties", #selector(properties(_:)), e.url)
        }
        return m
    }

    private func iconSizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Icon Size", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (t, s) in [("Small (16x16)", 16), ("Medium (22x22)", 22), ("Large (32x32)", 32), ("Huge (48x48)", 48)] {
            let it = sm.addItem(withTitle: t, action: #selector(setIconSize(_:)), keyEquivalent: "")
            it.target = self
            it.tag = s
            it.state = Settings.shared.placesIconSize == s ? .on : .off
        }
        item.submenu = sm
        return item
    }

    @objc private func openNewTab(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, open: u, newTab: true, splitView: false) }
    }
    @objc private func openSplit(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, open: u, newTab: false, splitView: true) }
    }
    @objc private func openNewWindow(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { AppDelegate.shared.newWindow(at: u) }
    }
    @objc private func properties(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, properties: u) }
    }
    @objc private func emptyTrash() { delegate?.places(self, emptyTrash: ()) }
    @objc private func ejectMenu(_ s: NSMenuItem) { if let e = s.representedObject as? PlaceEntry { eject(e) } }
    @objc private func toggleShowHidden() { PlacesModel.shared.showHidden.toggle() }
    @objc private func showSections() { PlacesModel.shared.hiddenSections = [] }
    @objc private func setIconSize(_ s: NSMenuItem) { Settings.shared.placesIconSize = s.tag }
    @objc private func resetPlaces() { PlacesModel.shared.resetDefaults() }
    @objc private func addNetworkFolder() { AddNetworkFolderDialog.run(window: window) }

    @objc private func toggleSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { toggleSectionAnimated(sec) }
    }

    @objc private func toggleAllSections() {
        let m = PlacesModel.shared
        let new: Set<PlaceSection> = m.collapsedSections.isEmpty ? Set(m.sections().map(\.0)) : []
        guard new != m.collapsedSections else { return }
        animateNextReload = true
        m.collapsedSections = new
    }

    @objc private func toggleLock() { PlacesModel.shared.isLocked.toggle() }

    @objc private func moveSectionUp(_ s: NSMenuItem) { moveSection(s, by: -1) }
    @objc private func moveSectionDown(_ s: NSMenuItem) { moveSection(s, by: 1) }

    /// Moves a section past its visible neighbour (hidden or empty sections keep their place in the stored order).
    private func moveSection(_ s: NSMenuItem, by delta: Int) {
        guard let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) else { return }
        let shown = PlacesModel.shared.sections().map(\.0)
        guard let n = shown.firstIndex(of: sec), shown.indices.contains(n + delta) else { return }
        if delta < 0 { PlacesModel.shared.moveSection(sec, before: shown[n - 1]) }
        else { PlacesModel.shared.moveSection(sec, before: n + 2 < shown.count ? shown[n + 2] : nil) }
    }

    @objc private func hideSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { PlacesModel.shared.hiddenSections.insert(sec) }
    }

    @objc private func showSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { PlacesModel.shared.hiddenSections.remove(sec) }
    }

    @objc private func toggleHidden(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlacesModel.shared.setHidden(e, !e.hidden)
    }

    @objc private func removeEntry(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlacesModel.shared.remove(e)
    }

    @objc private func editEntry(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlaceEditDialog.run(title: "Edit Places Entry", label: e.title, url: e.url, window: window) { label, url in
            PlacesModel.shared.update(e, title: label, url: url)
        }
    }

    @objc private func addEntry() {
        let u = currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let label = PlacesModel.shared.title(for: u) ?? (RemoteFS.isRemote(u) ? RemoteFS.displayName(for: u) : u.lastPathComponent)
        PlaceEditDialog.run(title: "Add Places Entry", label: label, url: u, window: window) { label, url in
            PlacesModel.shared.add(url, title: label)
        }
    }

    // MARK: Eject

    /// Ejects in the background (it can take seconds); the view leaves the volume first so it doesn't keep it busy.
    private func eject(_ e: PlaceEntry) {
        guard ejecting.insert(e.url).inserted else { return }
        // Every view showing the volume (all windows, tabs and split sides) must let go of it.
        MainWindowController.leaveVolume(e.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: e.url); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ejecting.remove(e.url)
                guard let failure else { return }
                let a = NSAlert(error: failure)
                a.messageText = "Could not eject “\(e.title)”"
                if let w = self.window { a.beginSheetModal(for: w) } else { a.runModal() }
            }
        }
    }

    // MARK: Drops (files onto entries, folders to add, reorder)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let i = rowIndex(at: p)
        let insertion = i.map { p.y < rows[$0].y + rows[$0].height / 2 ? $0 : $0 + 1 } ?? rows.count
        if let sec = draggedSection(sender.draggingPasteboard) {
            guard !PlacesModel.shared.isLocked else { return setDrop(nil, insert: nil) }
            let target = sectionDropTarget(at: p)
            sectionDrop = target
            // Dropping right above or below itself changes nothing: no marker.
            guard PlacesModel.shared.canMoveSection(sec, before: target) else { return setDrop(nil, insert: nil) }
            let hdr = target.flatMap { t in rows.indices.first { header(at: $0) == t } }
            // The marker goes in the gap above the target section (or below the last one), also when sections are folded.
            let y = hdr.map { rows[$0].y - Metrics.sectionGap / 2 } ?? ((rows.last.map { $0.y + $0.height } ?? 0) + Metrics.sectionGap / 2)
            setDrop(nil, insert: nil, sectionY: max(1, y))
            return .move
        }
        if let moving = draggedPlace(sender.draggingPasteboard) {
            guard !PlacesModel.shared.isLocked else { return setDrop(nil, insert: nil) }
            guard let d = reorderDestination(insertBefore: insertion, section: moving.section),
                  PlacesModel.shared.canMove(moving, before: d.target, endOf: d.section) else { return setDrop(nil, insert: nil) }
            setDrop(nil, insert: insertion)
            return .move
        }
        // Devices, tags and detected places can't be reordered (and are already listed).
        if sender.draggingPasteboard.types?.contains(.placeEntry) == true { return setDrop(nil, insert: nil) }
        let allFolders = draggedURLsAreFolders(sender)
        if let i, let e = entry(at: i), e.url.isFileURL {
            // Near the row edges with folders: insert as new place; in the middle: drop onto the place.
            let r = rect(of: i)
            if allFolders && !PlacesModel.shared.isLocked && (p.y < r.minY + Metrics.dropEdge || p.y > r.maxY - Metrics.dropEdge) {
                setDrop(nil, insert: p.y < r.minY + Metrics.dropEdge ? i : i + 1)
                return .link
            }
            setDrop(i, insert: nil)
            return ItemListView.operation(for: sender)
        }
        if allFolders && !PlacesModel.shared.isLocked {
            setDrop(nil, insert: insertion)
            return .link
        }
        return setDrop(nil, insert: nil)
    }

    /// Section being dropped before (nil = at the end), from the pointer: the upper half of a section's block
    /// (header plus its rows) drops before it, the lower half before the next one.
    private var sectionDrop: PlaceSection?

    private func sectionDropTarget(at p: CGPoint) -> PlaceSection? {
        let headers = rows.indices.filter { header(at: $0) != nil }
        for (n, h) in headers.enumerated() {
            let top = rows[h].y
            let bottom = n + 1 < headers.count ? rows[headers[n + 1]].y : (rows.last.map { $0.y + $0.height } ?? top)
            if p.y < (top + bottom) / 2 { return header(at: h) }
            if p.y < bottom { return n + 1 < headers.count ? header(at: headers[n + 1]) : nil }
        }
        return nil
    }

    private func draggedSection(_ pb: NSPasteboard) -> PlaceSection? {
        pb.string(forType: .placeSection).flatMap(PlaceSection.init(rawValue:))
    }

    /// Where a dragged section would land (the insertion line's y).
    private var sectionInsertY: CGFloat?

    @discardableResult
    private func setDrop(_ i: Int?, insert: Int?, sectionY: CGFloat? = nil) -> NSDragOperation {
        if i != dropIndex || insert != dropInsertBefore || sectionY != sectionInsertY {
            dropIndex = i
            dropInsertBefore = insert
            sectionInsertY = sectionY
            needsDisplay = true
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDrop(nil, insert: nil)
        dragFolderCheck = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDrop(nil, insert: nil); dragFolderCheck = nil }
        let pb = sender.draggingPasteboard
        if let sec = draggedSection(pb) {
            guard !PlacesModel.shared.isLocked else { return false }
            PlacesModel.shared.moveSection(sec, before: sectionDrop)
            return true
        }
        if let moving = draggedPlace(pb) {
            guard let ins = dropInsertBefore, let d = reorderDestination(insertBefore: ins, section: moving.section) else { return false }
            PlacesModel.shared.move(moving, before: d.target, endOf: d.section)
            return true
        }
        let urls = Self.fileURLs(pb)
        guard !urls.isEmpty else { return false }
        if let e = entry(at: dropIndex) {
            delegate?.places(self, drop: urls, onto: e.url)
            return true
        }
        guard let ins = dropInsertBefore, !PlacesModel.shared.isLocked else { return false }
        // New folders land where they were dropped when that is inside the Places section (the model's
        // reload renumbers rows, so the destination is resolved first).
        let d = reorderDestination(insertBefore: ins, section: .places)
        for u in urls {
            PlacesModel.shared.add(u)
            if let d, let added = PlacesModel.shared.userEntries.last(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) {
                PlacesModel.shared.move(added, before: d.target, endOf: d.section)
            }
        }
        return true
    }

    /// Where an insertion before row `ins` lands within `section`: before one of its entries, or at its end.
    private func reorderDestination(insertBefore ins: Int, section: PlaceSection) -> (target: PlaceEntry?, section: PlaceSection)? {
        if let t = entry(at: ins), t.section == section { return (t, section) }
        if let above = entry(at: ins - 1), above.section == section { return (nil, section) }
        // Just above the section's own header: its top.
        if ins < rows.count, case .header(let sec) = rows[ins].kind, sec == section, let first = entry(at: ins + 1) { return (first, section) }
        return nil
    }

    /// The place being dragged (from this or another window's panel), looked up in the model.
    private func draggedPlace(_ pb: NSPasteboard) -> PlaceEntry? {
        guard let s = pb.string(forType: .placeEntry), let nl = s.lastIndex(of: "\n") else { return nil }
        let title = String(s[..<nl]), url = String(s[s.index(after: nl)...])
        return PlacesModel.shared.userEntries.first { $0.title == title && $0.url.absoluteString == url }
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func draggedURLsAreFolders(_ sender: NSDraggingInfo) -> Bool {
        if let c = dragFolderCheck, c.sequence == sender.draggingSequenceNumber { return c.allFolders }
        let urls = Self.fileURLs(sender.draggingPasteboard)
        let all = !urls.isEmpty && urls.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        dragFolderCheck = (sender.draggingSequenceNumber, all)
        return all
    }
}

extension PlacesPanel: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .link, .generic] : [.copy, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingRow = false
        pressed = nil
    }
}

extension NSPasteboard.PasteboardType {
    static let placeEntry = NSPasteboard.PasteboardType("app.porpoise.Porpoise.place")
    static let placeSection = NSPasteboard.PasteboardType("app.porpoise.Porpoise.place-section")
}

// MARK: - Dialogs

/// "Edit Places Entry" dialog (label + location).
enum PlaceEditDialog {
    static func run(title: String, label: String, url: URL, window: NSWindow?, done: @escaping (String, URL) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 58))
        let l1 = NSTextField(labelWithString: "Label:"); l1.frame = CGRect(x: 0, y: 34, width: 70, height: 20)
        let f1 = NSTextField(string: label); f1.frame = CGRect(x: 74, y: 32, width: 286, height: 24)
        let l2 = NSTextField(labelWithString: "Location:"); l2.frame = CGRect(x: 0, y: 4, width: 70, height: 20)
        let f2 = NSTextField(string: url.isFileURL ? url.path : url.absoluteString); f2.frame = CGRect(x: 74, y: 2, width: 286, height: 24)
        [l1, f1, l2, f2].forEach(v.addSubview)
        a.accessoryView = v
        a.window.initialFirstResponder = f1
        let handler: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            let raw = f2.stringValue.trimmingCharacters(in: .whitespaces)
            let u = location(raw, old: url)
            let label = f1.stringValue.trimmingCharacters(in: .whitespaces)
            done(label.isEmpty ? defaultLabel(for: u) : label, u)
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handler) } else { handler(a.runModal()) }
    }

    /// The typed location: unchanged text (or none) keeps the old URL, so virtual places such as "recent:/files" or
    /// "network:/" survive editing only the label; "scheme:…" is a URL; anything else is a path ("~" expanded).
    private static func location(_ raw: String, old: URL) -> URL {
        if raw.isEmpty || raw == (old.isFileURL ? old.path : old.absoluteString) { return old }
        if raw.hasPrefix("file://"), let u = URL(string: raw), u.isFileURL { return u }
        if let remote = RemoteFS.parseTyped(raw) { return remote }   // sftp://…, user@host:path
        if !raw.hasPrefix("/"), !raw.hasPrefix("~"), let u = URL(string: raw), let scheme = u.scheme, scheme.count > 1 { return u }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private static func defaultLabel(for u: URL) -> String {
        let name = u.lastPathComponent
        if name.isEmpty || name == "/" { return u.isFileURL ? "/" : (u.host ?? u.absoluteString) }
        return name
    }
}

/// Dolphin's "Add Network Folder" wizard (also the Mac's "Connect to Server…", ⌘K).
enum AddNetworkFolderDialog {
    static let kinds: [(title: String, scheme: String, port: Int)] = [
        ("SSH / SFTP", "sftp", 22), ("FTP", "ftp", 21), ("FTPS (FTP over TLS)", "ftps", 21),
        ("Windows share (SMB)", "smb", 445), ("WebDAV", "webdav", 80), ("WebDAV (secure)", "webdavs", 443),
        ("NFS", "nfs", 2049), ("Apple file server (AFP)", "afp", 548),
    ]

    static func run(window: NSWindow?, open: ((URL) -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = "Add Network Folder"
        a.informativeText = "Connect to a server and add it to Places."
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 210))
        func label(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = CGRect(x: 0, y: y + 3, width: 96, height: 18)
            v.addSubview(l)
        }
        func field(_ y: CGFloat, _ placeholder: String) -> NSTextField {
            let f = NSTextField(frame: CGRect(x: 104, y: y, width: 276, height: 24))
            f.placeholderString = placeholder
            v.addSubview(f)
            return f
        }
        label("Type:", 180)
        let type = NSPopUpButton(frame: CGRect(x: 102, y: 178, width: 280, height: 26), pullsDown: false)
        type.addItems(withTitles: kinds.map(\.title))
        v.addSubview(type)
        label("Name:", 146); let name = field(146, "My server")
        label("Server:", 116); let server = field(116, "example.com or 192.168.1.10")
        label("Port:", 86); let port = field(86, "22")
        label("User:", 56); let user = field(56, NSUserName())
        label("Folder:", 26); let folder = field(26, "/home/me or share name")
        let add = NSButton(checkboxWithTitle: "Add to Places", target: nil, action: nil)
        add.state = .on
        add.frame = CGRect(x: 102, y: 0, width: 200, height: 20)
        v.addSubview(add)
        a.accessoryView = v
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = server
        let handler: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn, !server.stringValue.isEmpty else { return }
            let k = kinds[type.indexOfSelectedItem]
            var c = URLComponents()
            c.scheme = k.scheme
            c.host = server.stringValue.trimmingCharacters(in: .whitespaces)
            if let p = Int(port.stringValue), p != k.port { c.port = p }
            if !user.stringValue.isEmpty { c.user = user.stringValue }
            var path = folder.stringValue.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty && !path.hasPrefix("/") { path = (k.scheme == "sftp" ? "/~/" : "/") + path }
            c.path = path.isEmpty ? "/" : path
            guard let url = c.url else { return }
            if add.state == .on { PlacesModel.shared.add(url, title: name.stringValue.isEmpty ? nil : name.stringValue) }
            if let open { open(url) } else if let wc = window?.windowController as? MainWindowController { wc.view.setURL(url) }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handler) } else { handler(a.runModal()) }
    }
}
