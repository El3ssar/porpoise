import AppKit
import PorpoiseCore
import PorpoiseServices

enum CompareSymbols {
    static let onlyLeft = "◧", onlyRight = "◨"
    static func drawOnly(_ side: SyncSide, centeredAt center: CGPoint, color: NSColor) {
        let rect = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        let box = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSGraphicsContext.saveGraphicsState(); box.addClip(); color.setFill()
        CGRect(x: side == .left ? rect.minX : rect.midX, y: rect.minY, width: 6, height: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        color.setStroke(); box.lineWidth = 1.25; box.stroke()
    }
}

/// Both Details panes and their seam share a single virtualized clip/document, so scrolling cannot drift.
final class CompareRowsView: NSView, NSAccessibilityCustomRotorItemSearchDelegate {
    private var accessibleRows: [String: CompareAccessibleRow] = [:]
    var model: CompareModel
    var rows: [SyncDifference] = []
    var finishedPaths = Set<String>()
    var failedPaths = Set<String>()
    var selectedPath: String?
    var activeSide: SyncSide = .left
    var hoverIndex: Int?
    var gutterWidth: CGFloat = 28
    var rowHeight: CGFloat = 28
    var onOpen: ((SyncDifference) -> Void)?
    var onCopy: ((SyncDifference, SyncSide) -> Void)?
    var onSelection: ((SyncDifference, SyncSide) -> Void)?
    var onExit: (() -> Void)?
    var onPopover: ((SyncDifference, CGRect) -> Void)?
    var entryOrigins: [String: CGFloat] = [:]
    private let animator = Animator()
    private var transition: ItemTransition?
    private var leaving: [(SyncDifference, CGFloat)] = []
    private var indices: [String: Int] = [:]
    private var tracking: NSTrackingArea?
    private var hoverTicket = 0
    var filterMilliseconds: Double = 0
    var drawMilliseconds: [Double] = []
    var drawSampleTimes: [Double] = []
    var detailsDrawMilliseconds: [SyncSide: [Double]] = [:]
    init(model: CompareModel) {
        self.model = model; super.init(frame: .zero); wantsLayer = true
        setAccessibilityLabel("Folder comparison"); setAccessibilityRole(.outline)
        setAccessibilityCustomRotors([NSAccessibilityCustomRotor(label: "Differences", itemSearchDelegate: self)])
    }
    private(set) var detailsContainers: [ViewContainer] = []
    private var lastDetailsVersion = -1
    private var updatingDetailsProperties = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var syncingScroll = false
    private var detailsLayouts: [ObjectIdentifier: (CGSize, CGFloat, Int)] = [:]
    private func synchronizeScroll(from clip: NSClipView) {
        guard !syncingScroll else { return }
        syncingScroll = true
        for scroll in detailsContainers.map(\.scroll) + [enclosingScrollView].compactMap({ $0 }) where scroll.contentView !== clip {
            scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        syncingScroll = false
    }
    func observeScrolls() {
        scrollObservers.forEach(NotificationCenter.default.removeObserver); scrollObservers = []
        for scroll in detailsContainers.map(\.scroll) + [enclosingScrollView].compactMap({ $0 }) {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObservers.append(
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                    [weak self, weak scroll] _ in
                    if let clip = scroll?.contentView { self?.synchronizeScroll(from: clip) }
                })
        }
    }
    func attachDetails(_ containers: [ViewContainer]) {
        detachDetails()
        detailsContainers = containers
        let size = (containers.first(where: { $0.isActive }) ?? containers.first)?.model.props.iconSize(for: .details) ?? 22
        rowHeight = 2 * ItemListView.pad + max(size, containers.first?.list.lineHeight ?? 16) + 2
        for (index, container) in containers.enumerated() {
            let list = container.list
            var props = container.model.props; props.mode = .details; props.setIconSize(size, for: .details)
            props.sortRole = model.sortRole; props.sortOrder = model.sortAscending ? .ascending : .descending
            container.model.props = props
            list.comparisonExit = { [weak self] in self?.onExit?() }
            list.comparisonZoom = { [weak self] size in self?.setDetailsZoom(size) }
            list.comparisonSlots = []; list.comparisonSlotCount = container.model.rows.count
            list.comparisonRowHeight = rowHeight
            let side: SyncSide = index == 0 ? .left : .right
            container.model.onComparisonExpansion = { [weak self] url, on in
                guard let self, let path = LinkedBrowsing.relativePath(url, below: side == .left ? self.model.leftRoot : self.model.rightRoot) else {
                    return
                }
                let canonical = (side == .left ? self.model.leftDetails : self.model.rightDetails).pathAliases[path] ?? path
                if self.model.expanded.contains(canonical) != on { self.model.expand(canonical) }
            }
            container.comparisonPropsChanged = { [weak self, weak container] in
                guard let self, let container, !self.updatingDetailsProperties else { return }
                let props = container.model.props
                if self.model.sortRole != props.sortRole || self.model.sortAscending != (props.sortOrder == .ascending) {
                    self.model.sortRole = props.sortRole; self.model.sortAscending = props.sortOrder == .ascending
                    self.model.sortSide = side; self.model.invalidateSort()
                }
                self.updatingDetailsProperties = true
                for other in self.detailsContainers where other !== container {
                    var shared = other.model.props; shared.sortRole = props.sortRole; shared.sortOrder = props.sortOrder; other.model.props = shared
                    other.header.needsDisplay = true
                }
                self.updatingDetailsProperties = false
                self.detailsLayouts = [:]; self.layoutDetails()
            }
            container.comparisonSelectionChanged = { [weak self, weak container] in
                guard let self, let container else { return }
                self.activeSide = side
                let url = container.model.selection.first ?? container.model.currentURL
                self.selectedPath = url.flatMap { LinkedBrowsing.relativePath($0, below: side == .left ? self.model.leftRoot : self.model.rightRoot) }
                if let path = self.selectedPath {
                    self.selectedPath = (side == .left ? self.model.leftDetails : self.model.rightDetails).pathAliases[path] ?? path
                }
                if let path = self.selectedPath, let slot = self.model.rowIndices[path] { self.onSelection?(self.rows[slot], side) }
                self.needsDisplay = true
                self.detailsContainers.forEach { $0.list.needsDisplay = true }
            }
            list.comparisonGhostClick = { [weak self] point in
                guard let self else { return false }
                let slot = Int(point.y / self.rowHeight)
                guard self.rows.indices.contains(slot), (side == .left ? self.rows[slot].left : self.rows[slot].right) == nil else { return false }
                self.activeSide = side.opposite; self.select(slot); return true
            }
            list.comparisonColumnColor = { [weak self, weak list] index, role in
                guard let self, let slot = list?.comparisonSlots?[safe: index], self.rows.indices.contains(slot) else { return nil }
                let row = self.rows[slot]
                guard case .changed = row.status else { return nil }
                if role == .size && row.left?.size != row.right?.size { return Theme.compareChanged }
                if role == .modificationTime && row.left?.modified != row.right?.modified { return Theme.compareChanged }
                return nil
            }
            list.comparisonCaption = { [weak self, weak list] index in
                guard let self, let slot = list?.comparisonSlots?[safe: index], self.rows.indices.contains(slot) else { return nil }
                let row = self.rows[slot], entry = side == .left ? row.left : row.right
                let caption: String
                if let left = row.left, let right = row.right, left.kind != right.kind {
                    caption = entry?.kind == .directory ? "Folder here, file there" : "File here, folder there"
                } else if let left = row.left, let right = row.right,
                    (left.path as NSString).lastPathComponent != (right.path as NSString).lastPathComponent
                {
                    caption = "Name differs in case"
                } else if entry?.kind == .symlink, row.left?.linkTarget != row.right?.linkTarget {
                    caption = "Link targets differ"
                } else if entry?.kind == .directory, row.status != .same, !(self.model.loading && self.model.comparison?.complete == false) {
                    if row.status == .onlyLeft || row.status == .onlyRight {
                        let count = self.model.outline?.childCounts[side]?[row.path] ?? 0
                        caption = "\(count) only here"
                    } else {
                        let count = self.model.outline?.differenceCounts[row.path] ?? 0
                        caption = "\(count) \(count == 1 ? "difference" : "differences")"
                    }
                } else {
                    return nil
                }
                return (caption, self.color(row))
            }
            list.comparisonDrawTiming = { [weak self] milliseconds in
                self?.detailsDrawMilliseconds[side, default: []].append(milliseconds)
                if let count = self?.detailsDrawMilliseconds[side]?.count, count > 240 {
                    self?.detailsDrawMilliseconds[side]?.removeFirst(count - 240)
                }
            }
            list.drawComparisonBackground = { [weak self, weak list] dirty in
                guard let self, let list else { return }
                self.drawDetailsBackground(side: side, in: list, dirty: dirty)
            }
        }
        lastDetailsVersion = -1; observeScrolls(); updateDetails()
    }
    func detachDetails() {
        scrollObservers.forEach(NotificationCenter.default.removeObserver); scrollObservers = []
        for container in detailsContainers {
            let list = container.list
            list.comparisonSlots = nil; list.comparisonPaneWidth = nil
            list.comparisonRowHeight = nil; list.drawComparisonBackground = nil; list.comparisonZoom = nil; list.comparisonExit = nil;
            list.comparisonGhostClick = nil;
            list.comparisonDrawTiming = nil; list.comparisonColumnColor = nil; list.comparisonCaption = nil
            container.comparisonPropsChanged = nil; container.comparisonSelectionChanged = nil
            container.model.onComparisonExpansion = nil; container.comparisonMissingName = nil; container.comparisonMissingSideLabel = nil;
            container.statusBar.toolTip = nil
            container.addSubview(container.scroll); container.addSubview(container.header)
            container.addSubview(container.statusBar); container.needsLayout = true
        }
        detailsContainers = []; lastDetailsVersion = -1; detailsLayouts = [:]
    }
    func updateDetails() {
        // Keep the real browse rows on screen until the first aligned result is ready.
        guard model.detailsVersion > 0 else { layoutDetails(); return }
        guard lastDetailsVersion != model.detailsVersion else { return }
        lastDetailsVersion = model.detailsVersion
        for (index, container) in detailsContainers.enumerated() {
            let details = index == 0 ? model.leftDetails : model.rightDetails
            let root = index == 0 ? model.leftRoot : model.rightRoot
            let identity = index == 0 ? model.comparison?.leftRootIdentity : model.comparison?.rightRootIdentity
            container.comparisonMissingName =
                root.isFileURL && model.comparison != nil && identity == nil && !model.loading ? root.lastPathComponent : nil
            container.comparisonMissingSideLabel = index == 0 ? model.names.0 : model.names.1
            container.model.presentComparisonRows(details.rows, counts: details.counts, folderCounts: details.folderCounts)
            container.list.comparisonSlots = details.slots; container.list.comparisonSlotCount = rows.count
        }
        layoutDetails()
        for container in detailsContainers { container.comparisonRowsDidLoad() }
    }
    func setDetailsZoom(_ size: CGFloat) {
        let size = min(256, max(16, size))
        updatingDetailsProperties = true
        for container in detailsContainers {
            var props = container.model.props; props.setIconSize(size, for: .details); container.model.props = props
            container.statusBar.zoomLevel = ZoomLevels.continuousLevel(for: size)
        }
        updatingDetailsProperties = false
        rowHeight = 2 * ItemListView.pad + max(size, detailsContainers.first?.list.lineHeight ?? 16) + 2
        frame.size.height = max(enclosingScrollView?.contentSize.height ?? 0, CGFloat(rows.count) * rowHeight)
        layoutDetails(); needsDisplay = true
    }
    func layoutDetails() {
        for container in detailsContainers {
            let list = container.list
            let key = ObjectIdentifier(list), size = container.scroll.contentSize
            if let previous = detailsLayouts[key], previous.0 == size, previous.1 == rowHeight, previous.2 == model.detailsVersion { continue }
            detailsLayouts[key] = (size, rowHeight, model.detailsVersion)
            list.comparisonPaneWidth = nil; list.comparisonRowHeight = rowHeight
            list.relayout()
        }
    }
    private func drawDetailsBackground(side: SyncSide, in list: ItemListView, dirty: CGRect) {
        let first = max(0, Int(dirty.minY / rowHeight)), last = min(rows.count, Int(dirty.maxY / rowHeight) + 1)
        if rows.isEmpty, !model.loading, model.comparison?.complete == true {
            let counts = model.outline?.counts ?? [:]
            let matches = [CompareFilter.onlyLeft, .onlyRight, .changed].allSatisfy { (counts[$0.rawValue] ?? 0) == 0 }
            let message = matches ? "No differences · Show Same to see matching items" : "No items match these filters"
            text(
                message, CGRect(x: list.visibleRect.minX + 12, y: list.visibleRect.midY - 30, width: list.visibleRect.width - 24, height: 24),
                size: 15, color: Theme.viewTextInactive, align: .center)
        }
        guard first < last else { return }
        for index in first..<last {
            let row = rows[index], entry = side == .left ? row.left : row.right
            let rect = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: list.bounds.width, height: rowHeight)
            if !index.isMultiple(of: 2) { Theme.viewAlternate.setFill(); rect.fill() }
            let opposite = detailsContainers[side == .left ? 1 : 0]
            if let counterpart = side == .left ? row.right : row.left {
                let root = side == .left ? model.rightRoot : model.leftRoot
                if opposite.model.selection.contains(root.appendingPathComponent(counterpart.path)) {
                    let outline = NSBezierPath(
                        roundedRect: rect.insetBy(dx: ItemListView.sidePadding, dy: 1), xRadius: Theme.itemRadius, yRadius: Theme.itemRadius)
                    Theme.itemSelectedOutline.setStroke(); outline.stroke()
                }
            }
            if entry == nil {
                let ghost = NSBezierPath(
                    roundedRect: rect.insetBy(dx: ItemListView.sidePadding, dy: 3), xRadius: Theme.itemRadius, yRadius: Theme.itemRadius)
                Theme.viewTextInactive.withAlphaComponent(0.2).setStroke(); ghost.setLineDash([3, 3], count: 2, phase: 0); ghost.stroke()
            } else if row.status != .same && (entry?.kind != .directory || row.status == .onlyLeft || row.status == .onlyRight) {
                color(row).withAlphaComponent(Theme.increasedContrast ? 0.18 : (effectiveAppearance.isDark ? 0.11 : 0.08)).setFill(); rect.fill()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var seam: CGRect { CGRect(x: (bounds.width - gutterWidth) / 2, y: 0, width: gutterWidth, height: bounds.height) }
    func pane(_ side: SyncSide, y: CGFloat) -> CGRect {
        let width = (bounds.width - gutterWidth) / 2
        return CGRect(x: side == .left ? 0 : width + gutterWidth, y: y, width: width, height: rowHeight)
    }
    func replaceRows(_ next: [SyncDifference], indices nextIndices: [String: Int]) {
        let started = CACurrentMediaTime()
        let visible = visibleRect
        var from: [String: CGRect] = [:]
        let first = max(0, Int(visible.minY / rowHeight) - 1), last = min(rows.count, Int(visible.maxY / rowHeight) + 2)
        if first < last {
            for index in first..<last { from[rows[index].path] = CGRect(x: 0, y: y(index), width: bounds.width, height: rowHeight) }
        }
        for (path, position) in entryOrigins where from[path] == nil {
            from[path] = CGRect(x: 0, y: position, width: bounds.width, height: rowHeight)
        }
        entryOrigins = [:]
        let old = first < last ? Array(rows[first..<last]) : []
        animator.stop(); rows = next
        indices = nextIndices
        leaving = old.compactMap { row in indices[row.path] == nil ? from[row.path].map { (row, $0.minY) } : nil }
        frame.size.height = max(enclosingScrollView?.contentSize.height ?? 0, CGFloat(rows.count) * rowHeight)
        if let selectedPath, indices[selectedPath] == nil { self.selectedPath = nil }
        let reduce = !detailsContainers.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || next.count > 3000
        transition = ItemTransition(from: reduce ? [:] : from, leaving: [], progress: 0)
        if reduce { leaving = [] }
        animator.run(
            duration: reduce ? 0.12 : 0.18, curve: Animator.easeOutCubic,
            step: { [weak self] value in
                self?.transition?.progress = CGFloat(value); self?.needsDisplay = true
            },
            completion: { [weak self] in
                self?.transition = nil; self?.leaving = []; self?.needsDisplay = true
            })
        needsDisplay = true
        filterMilliseconds = (CACurrentMediaTime() - started) * 1000
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    private func y(_ index: Int) -> CGFloat {
        let end = CGFloat(index) * rowHeight
        guard let transition, let start = transition.from[rows[index].path] else { return end }
        return start.minY + (end - start.minY) * transition.progress
    }
    override func draw(_ dirty: NSRect) {
        let started = CACurrentMediaTime()
        Theme.viewBackground.setFill(); dirty.fill()
        Theme.windowBackground.setFill(); seam.intersection(dirty).fill()
        Theme.hairline.setFill()
        CGRect(x: seam.minX, y: dirty.minY, width: 1, height: dirty.height).fill()
        CGRect(x: seam.maxX - 1, y: dirty.minY, width: 1, height: dirty.height).fill()
        var candidates = Set<Int>()
        let first = max(0, Int(dirty.minY / rowHeight) - 1), last = min(rows.count, Int(dirty.maxY / rowHeight) + 2)
        if first < last { candidates.formUnion(first..<last) }
        if let transition { for key in transition.from.keys { if let index = indices[key] { candidates.insert(index) } } }
        for index in candidates.sorted() {
            let position = y(index)
            guard CGRect(x: 0, y: position, width: bounds.width, height: rowHeight).intersects(dirty) else { continue }
            drawRow(
                rows[index], index: index, y: position, alpha: transition?.from[rows[index].path] == nil ? transition?.progress ?? 1 : 1, dirty: dirty
            )
        }
        if let transition { for (row, position) in leaving { drawRow(row, index: 0, y: position, alpha: 1 - transition.progress, dirty: dirty) } }
        drawMilliseconds.append((CACurrentMediaTime() - started) * 1000)
        drawSampleTimes.append(started)
        if drawMilliseconds.count > 240 { drawMilliseconds.removeFirst(drawMilliseconds.count - 240) }
        if drawSampleTimes.count > 240 { drawSampleTimes.removeFirst(drawSampleTimes.count - 240) }
    }
    func color(_ row: SyncDifference) -> NSColor {
        if failedPaths.contains(row.path) { return Theme.compareDanger }
        switch row.status {
        case .onlyLeft, .onlyRight: return Theme.compareOnly;
        case .same: return Theme.windowTextInactive.withAlphaComponent(0.45)
        case .collision: return Theme.compareDanger;
        default: return Theme.compareChanged
        }
    }
    func glyph(_ row: SyncDifference) -> String {
        if failedPaths.contains(row.path) { return "!" }
        if finishedPaths.contains(row.path) { return "✓" }
        if let choice = model.overrides[row.path] { return choice == .keepRight ? "←" : "→" }
        if (row.left ?? row.right)?.kind == .directory, case .changed = row.status { return "○" }
        switch row.status {
        case .onlyLeft: return CompareSymbols.onlyLeft;
        case .onlyRight: return CompareSymbols.onlyRight;
        case .same: return "=";
        case .collision: return "!";
        default: return "≠"
        }
    }
    private func drawRow(_ row: SyncDifference, index: Int, y: CGFloat, alpha: CGFloat, dirty: NSRect) {
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard seam.intersects(dirty) else { return }
        if model.loading && model.comparison?.complete == false && row.left?.kind == .directory && row.right?.kind == .directory {
            let arc = NSBezierPath(); arc.lineWidth = 1.5
            let angle = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 1.2) / 1.2 * 360)
            arc.appendArc(withCenter: CGPoint(x: seam.midX, y: y + rowHeight / 2), radius: 4, startAngle: angle, endAngle: angle + 270)
            Theme.accent.setStroke(); arc.stroke()
        } else {
            let symbol = glyph(row), center = CGPoint(x: seam.midX, y: y + rowHeight / 2)
            if symbol == CompareSymbols.onlyLeft || symbol == CompareSymbols.onlyRight {
                CompareSymbols.drawOnly(symbol == CompareSymbols.onlyLeft ? .left : .right, centeredAt: center, color: color(row))
            } else if symbol == "○" {
                color(row).setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                ring.lineWidth = 1.5; ring.stroke()
                color(row).setFill(); NSBezierPath(ovalIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
            } else {
                text(
                    symbol, CGRect(x: seam.minX + 2, y: y + (rowHeight - 20) / 2, width: max(0, seam.width - 4), height: 20), size: 16,
                    color: color(row), align: .center)
            }
        }
        if case .changed(let newer) = row.status, newer != .unknown {
            color(row).setFill();
            NSBezierPath(ovalIn: CGRect(x: seam.midX + (newer == .newerLeft ? -10 : 6), y: y + rowHeight / 2 - 2, width: 4, height: 4)).fill()
        }
    }
    func text(_ string: String, _ rect: CGRect, size: CGFloat, color: NSColor, align: NSTextAlignment = .left, weight: NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle; style.alignment = align
        (string as NSString).draw(
            in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), index = Int(point.y / rowHeight)
        hoverIndex = rows.indices.contains(index) ? index : nil; needsDisplay = true
        hoverTicket += 1; let ticket = hoverTicket
        if seam.contains(point), rows.indices.contains(index) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, self.hoverTicket == ticket, self.rows.indices.contains(index) else { return }
                self.onPopover?(self.rows[index], CGRect(x: self.seam.minX, y: CGFloat(index) * self.rowHeight, width: 28, height: self.rowHeight))
            }
        }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverTicket += 1; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil), index = Int(point.y / rowHeight)
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        activeSide = point.x < seam.midX ? .left : .right
        if (activeSide == .left ? row.left : row.right) == nil { activeSide = activeSide.opposite }
        selectedPath = row.path; onSelection?(row, activeSide)
        if seam.contains(point) {
            model.overrides[row.path] = model.overrides[row.path] == .keepLeft ? .keepRight : .keepLeft
        } else if event.clickCount == 2 {
            onOpen?(row)
        } else if (row.left ?? row.right)?.kind == .directory
            && point.x - pane(activeSide, y: 0).minX < 26 + CGFloat(row.path.split(separator: "/").count - 1) * 14
        {
            model.expand(row.path)
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }
    override func keyDown(with event: NSEvent) {
        if !detailsContainers.isEmpty {
            let list = detailsContainers[activeSide == .left ? 0 : 1].list
            window?.makeFirstResponder(list); list.keyDown(with: event); return
        }
        let index = selectedPath.flatMap { indices[$0] } ?? -1
        switch event.keyCode {
        case 53: onExit?()
        case 125, 126:
            let next = max(0, min(rows.count - 1, index + (event.keyCode == 125 ? 1 : -1)))
            if rows.indices.contains(next) { select(next) }
        case 123, 124:
            if event.modifierFlags.contains(.option) {
                activeSide = event.keyCode == 123 ? .left : .right; needsDisplay = true
                if rows.indices.contains(index) { onSelection?(rows[index], activeSide) }
            } else if rows.indices.contains(index) {
                model.expand(rows[index].path)
            }
        case 36: if rows.indices.contains(index) { onOpen?(rows[index]) }
        case 49: if rows.indices.contains(index) { model.expand(rows[index].path) }
        default: super.keyDown(with: event)
        }
    }
    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        if !detailsContainers.isEmpty {
            let container = detailsContainers[activeSide == .left ? 0 : 1]
            if let entry = activeSide == .left ? rows[index].left : rows[index].right {
                container.list.select((activeSide == .left ? model.leftRoot : model.rightRoot).appendingPathComponent(entry.path))
                window?.makeFirstResponder(container.list)
            }
        }
        selectedPath = rows[index].path; onSelection?(rows[index], activeSide); needsDisplay = true
        scrollToVisible(CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight))
    }
    func difference(forward: Bool) {
        let start = selectedPath.flatMap { indices[$0] } ?? (forward ? -1 : rows.count)
        let sequence = forward ? Array((start + 1)..<rows.count) : Array(0..<max(0, start)).reversed().map { $0 }
        if let index = sequence.first(where: { rows[$0].status != .same }) { select(index) }
    }
    func describe(_ row: SyncDifference) -> String {
        switch row.status {
        case .onlyLeft: return "only in \(model.names.0)"
        case .onlyRight: return "only in \(model.names.1)"
        case .same: return "identical by \(CompareView.methodTitle(model.options.method).lowercased())"
        case .collision: return "name collision"
        case .changed(let newer): return "changed" + (newer == .unknown ? "" : ", newer in \(newer == .newerLeft ? model.names.0 : model.names.1)")
        }
    }
    private func accessible(_ index: Int, side: SyncSide) -> CompareAccessibleRow {
        let row = rows[index], key = row.path + ":" + side.rawValue
        if accessibleRows.count > 200 { accessibleRows.removeAll() }
        let element = accessibleRows[key] ?? CompareAccessibleRow(list: self, path: row.path, side: side)
        accessibleRows[key] = element
        element.setAccessibilityLabel(
            "\(side == .left ? model.names.0 : model.names.1): \((row.path as NSString).lastPathComponent), \(describe(row)), \(row.left?.size ?? 0) bytes versus \(row.right?.size ?? 0) bytes"
        )
        element.setAccessibilitySelected(row.path == selectedPath)
        let rect = pane(side, y: CGFloat(index) * rowHeight)
        element.setAccessibilityFrame(window?.convertToScreen(convert(rect, to: nil)) ?? .zero)
        return element
    }
    override func accessibilityChildren() -> [Any]? {
        let first = max(0, Int(visibleRect.minY / rowHeight)), last = min(rows.count, Int(visibleRect.maxY / rowHeight) + 1)
        guard first < last else { return [] }
        return (first..<last).flatMap { index -> [CompareAccessibleRow] in
            [SyncSide.left, .right].compactMap { side in
                (side == .left ? rows[index].left : rows[index].right) == nil ? nil : accessible(index, side: side)
            }
        }
    }
    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters)
        -> NSAccessibilityCustomRotor.ItemResult?
    {
        let current = (searchParameters.currentItem?.targetElement as? CompareAccessibleRow)?.path
        let forward = searchParameters.searchDirection == .next
        let start = current.flatMap { indices[$0] } ?? (forward ? -1 : rows.count)
        let indexes = forward ? Array((start + 1)..<rows.count) : Array(0..<max(0, start)).reversed().map { $0 }
        guard
            let index = indexes.first(where: {
                rows[$0].status != .same
                    && (searchParameters.filterString.isEmpty || rows[$0].path.localizedCaseInsensitiveContains(searchParameters.filterString))
            })
        else { return nil }
        let side: SyncSide = rows[index].left == nil ? .right : .left
        return NSAccessibilityCustomRotor.ItemResult(targetElement: accessible(index, side: side))
    }
}

private final class CompareAccessibleRow: NSAccessibilityElement, NSAccessibilityElementProtocol {
    weak var list: CompareRowsView?
    let path: String
    let side: SyncSide
    init(list: CompareRowsView, path: String, side: SyncSide) {
        self.list = list; self.path = path; self.side = side; super.init()
        setAccessibilityParent(list); setAccessibilityRole(.row); setAccessibilityEnabled(true)
    }
    override func accessibilityIdentifier() -> String { path + ":" + side.rawValue }
    override func accessibilityPerformPress() -> Bool {
        guard let list, let index = list.rows.firstIndex(where: { $0.path == path }) else { return false }
        list.activeSide = side; list.select(index); list.onOpen?(list.rows[index]); return true
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused, let list, let index = list.rows.firstIndex(where: { $0.path == path }) { list.activeSide = side; list.select(index) }
    }
}
