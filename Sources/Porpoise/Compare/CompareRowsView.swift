import AppKit
import PorpoiseCore
import PorpoiseServices

enum CompareSymbols {
    static let onlyLeft = "◧", onlyRight = "◨"
    static func drawOnly(_ side: SyncSide, centeredAt center: CGPoint, color: NSColor) {
        let rect = CGRect(x: center.x - 7, y: center.y - 4.5, width: 14, height: 9)
        let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState(); box.addClip(); color.setFill()
        CGRect(x: side == .left ? rect.minX : rect.midX, y: rect.minY, width: 7, height: 9).fill()
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
    var selectedPath: String?
    var activeSide: SyncSide = .left
    var hoverIndex: Int?
    var gutterWidth: CGFloat = 28
    var rowHeight: CGFloat = 28
    var dateWidths: [SyncSide: CGFloat] = [:]
    var sizeWidths: [SyncSide: CGFloat] = [:]
    func widths(_ side: SyncSide, paneWidth: CGFloat) -> (date: CGFloat, size: CGFloat) {
        (paneWidth > 350 ? min(paneWidth - 180, dateWidths[side] ?? 114) : 0, paneWidth > 240 ? sizeWidths[side] ?? 60 : 0)
    }
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
    init(model: CompareModel) {
        self.model = model; super.init(frame: .zero); wantsLayer = true
        setAccessibilityLabel("Folder comparison"); setAccessibilityRole(.outline)
        setAccessibilityCustomRotors([NSAccessibilityCustomRotor(label: "Differences", itemSearchDelegate: self)])
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
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || next.count > 3000
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
            drawRow(rows[index], index: index, y: position, alpha: transition?.from[rows[index].path] == nil ? transition?.progress ?? 1 : 1)
        }
        if let transition { for (row, position) in leaving { drawRow(row, index: 0, y: position, alpha: 1 - transition.progress) } }
        drawMilliseconds.append((CACurrentMediaTime() - started) * 1000)
        if drawMilliseconds.count > 240 { drawMilliseconds.removeFirst(drawMilliseconds.count - 240) }
    }
    func color(_ row: SyncDifference) -> NSColor {
        switch row.status {
        case .onlyLeft, .onlyRight: return Theme.compareOnly;
        case .same: return Theme.windowTextInactive.withAlphaComponent(0.45)
        case .collision: return Theme.compareDanger;
        default: return Theme.compareChanged
        }
    }
    func glyph(_ row: SyncDifference) -> String {
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
    private func drawRow(_ row: SyncDifference, index: Int, y: CGFloat, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for side in [SyncSide.left, .right] {
            let rect = pane(side, y: y), entry = side == .left ? row.left : row.right
            let selected = selectedPath == row.path
            (index.isMultiple(of: 2) ? Theme.viewBackground : Theme.viewBackground.mixed(with: Theme.windowBackground, 0.5)).setFill(); rect.fill()
            if entry != nil && row.status != .same && (entry?.kind != .directory || row.status == .onlyLeft || row.status == .onlyRight) {
                color(row).withAlphaComponent(
                    Theme.increasedContrast ? 0.18 : (effectiveAppearance.isDark ? 0.11 : 0.08)
                ).setFill(); rect.fill()
            }
            if selected {
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1), xRadius: 6, yRadius: 6)
                if activeSide == side { Theme.selection.withAlphaComponent(0.32).setFill(); box.fill() }
                Theme.selection.withAlphaComponent(0.75).setStroke(); box.lineWidth = 1; box.stroke()
            }
            guard let entry else {
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 3), xRadius: 6, yRadius: 6)
                Theme.windowText.withAlphaComponent(Theme.increasedContrast ? 0.4 : 0.2).setStroke()
                if !Theme.increasedContrast { box.setLineDash([3, 3], count: 2, phase: 0) }
                box.stroke()
                if hoverIndex == index {
                    text(
                        "Not in \(side == .left ? model.names.0 : model.names.1)", rect.insetBy(dx: 20, dy: 6), size: 11,
                        color: Theme.windowTextInactive, align: .center)
                }
                continue
            }
            if Theme.increasedContrast && row.status != .same {
                color(row).setFill(); CGRect(x: side == .left ? rect.maxX - 2 : rect.minX, y: y, width: 2, height: rowHeight).fill()
            }
            drawEntry(entry, row: row, side: side, rect: rect)
        }
        if model.loading && model.comparison?.complete == false && (row.left ?? row.right)?.kind == .directory {
            let arc = NSBezierPath(); arc.lineWidth = 1.5
            let angle = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 1.2) / 1.2 * 360)
            arc.appendArc(withCenter: CGPoint(x: seam.midX, y: y + rowHeight / 2), radius: 4, startAngle: angle, endAngle: angle + 270)
            Theme.accent.setStroke(); arc.stroke()
        } else {
            let symbol = glyph(row), center = CGPoint(x: seam.midX, y: y + rowHeight / 2)
            if symbol == CompareSymbols.onlyLeft || symbol == CompareSymbols.onlyRight {
                CompareSymbols.drawOnly(symbol == CompareSymbols.onlyLeft ? .left : .right, centeredAt: center, color: color(row))
            } else if symbol == "○" {
                color(row).setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
                ring.lineWidth = 1.75; ring.stroke()
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
    private func drawEntry(_ entry: SyncEntry, row: SyncDifference, side: SyncSide, rect: CGRect) {
        let depth = entry.path.split(separator: "/").count - 1
        let x = rect.minX + 12 + CGFloat(depth) * 14
        if entry.kind == .directory {
            let arrow = model.expanded.contains(row.path) ? "go-down" : "go-next"
            Icons.shared.image(arrow, size: 16, selected: selectedPath == row.path && activeSide == side)?
                .draw(
                    in: CGRect(x: x - 10, y: rect.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 0.85,
                    respectFlipped: true, hints: nil)
        }
        let ext = (entry.path as NSString).pathExtension.lowercased()
        let iconName =
            entry.kind == .directory
            ? "folder"
            : [
                "html": "text-html", "jpg": "image-jpeg", "png": "image-png", "pdf": "application-pdf", "txt": "text-plain",
                "numbers": "x-office-spreadsheet", "zip": "application-zip",
            ][ext] ?? "application-octet-stream"
        let iconSize = max(16, rowHeight - 6)
        let icon =
            Icons.shared.image(iconName, size: iconSize, folder: entry.kind == .directory)
            ?? Icons.shared.image(entry.kind == .directory ? "folder" : "text-x-generic", size: iconSize)
        let iconRect = CGRect(x: x + 7, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let columns = widths(side, paneWidth: rect.width), dateWidth = columns.date, sizeWidth = columns.size
        let nameRect = CGRect(
            x: x + iconSize + 14, y: rect.midY - 9, width: max(30, rect.maxX - dateWidth - sizeWidth - x - iconSize - 26), height: 19)
        let name = (entry.path as NSString).lastPathComponent
        text(name, nameRect, size: 13, color: Theme.windowText)
        var caption: String?
        if entry.kind == .directory, row.status != .same {
            let count = model.outline?.children[row.path]?.count ?? 0
            if count > 0 {
                let differences = model.outline?.differenceCounts[row.path] ?? 0
                caption =
                    row.status == .onlyLeft || row.status == .onlyRight
                    ? "\(count) only here" : "\(differences) \(differences == 1 ? "difference" : "differences")"
            }
            if model.loading && model.comparison?.complete == false { caption = nil }
        } else if entry.kind == .symlink, row.left?.linkTarget != row.right?.linkTarget {
            caption = "Link targets differ"
        }
        if let l = row.left?.path, let r = row.right?.path, l != r { caption = side == .left ? "Name differs in case" : nil }
        if let caption {
            let nameWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            let remaining = nameRect.width - nameWidth - 8
            if remaining > 35 {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                let run = NSMutableAttributedString(
                    string: caption,
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: style])
                if let prefix = caption.split(separator: " ").first, Int(prefix) != nil {
                    run.addAttribute(.foregroundColor, value: color(row), range: NSRange(location: 0, length: prefix.utf16.count))
                }
                run.draw(in: CGRect(x: nameRect.minX + nameWidth + 8, y: rect.midY - 7, width: remaining, height: 16))
            }
        }
        let changed: Bool
        if case .changed = row.status { changed = entry.kind != .directory } else { changed = false }
        if sizeWidth > 0 {
            let count = model.outline?.childCounts[side]?[row.path] ?? 0
            let size =
                entry.kind == .directory
                ? (model.comparison?.complete == true ? "\(count.formatted()) \(count == 1 ? "item" : "items")" : "…") : FileFormat.size(entry.size)
            let differs = row.left?.size != row.right?.size
            text(
                size, CGRect(x: rect.maxX - dateWidth - sizeWidth - 10, y: rect.midY - 8, width: sizeWidth, height: 18), size: 11,
                color: changed && differs ? color(row) : Theme.windowTextInactive, align: .right)
        }
        if dateWidth > 0 {
            let date =
                entry.modified.map { date -> String in
                    if Calendar.current.isDateInToday(date) { return "Today " + Self.times.string(from: date) }
                    if Calendar.current.isDateInYesterday(date) { return "Yesterday " + Self.times.string(from: date) }
                    return Self.dates.string(from: date)
                } ?? "Unknown"
            text(
                date, CGRect(x: rect.maxX - dateWidth, y: rect.midY - 8, width: dateWidth - 10, height: 18), size: 11,
                color: changed && row.left?.modified != row.right?.modified ? color(row) : Theme.windowTextInactive, align: .right)
        }
    }
    private static let dates: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let times: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
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
