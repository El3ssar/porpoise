import AppKit
import PorpoiseCore

// MARK: - Layout

extension ItemListView {
    var visibleHeight: CGFloat { enclosingScrollView?.contentView.bounds.height ?? bounds.height }
    var visibleWidth: CGFloat { enclosingScrollView?.contentView.bounds.width ?? bounds.width }

    func relayout() {
        computeLayout()
        needsDisplay = true
    }

    /// Label lines in Icons mode; "Unlimited" (0) reserves room for 6 lines.
    var maxLabelLines: Int { Settings.shared.iconsMaxLines == 0 ? 6 : Settings.shared.iconsMaxLines }

    func computeLayout() {
        cloudRects = [:]
        frames = Array(repeating: .zero, count: model.rows.count)
        groupHeaderFrames = []
        let width = max(visibleWidth, 100)
        let contentSize: NSSize
        switch mode {
        case .icons: contentSize = layoutIcons(width: width)
        case .compact: contentSize = layoutCompact(width: width)
        case .details: contentSize = layoutDetails(width: width)
        }
        if frame.size != contentSize { setFrameSize(contentSize) }
        dropStaleIndexes()
        if let i = renamingIndex, i < frames.count { positionRenameField(i) }
    }

    /// Row indexes kept across a layout may point past the end once rows were removed.
    private func dropStaleIndexes() {
        let n = frames.count
        if let i = hoverIndex, i >= n { hoverIndex = nil }
        if let i = mouseDownIndex, i >= n { mouseDownIndex = nil }
        if let i = dropTargetIndex, i >= n { dropTargetIndex = nil }
    }

    private var groupHeaderHeight: CGFloat { model.groups.isEmpty ? 0 : lineHeight + 14 }

    private func iconsItemWidth() -> CGFloat {
        let level = CGFloat(ZoomLevels.continuousLevel(for: iconSize))
        let idx = CGFloat(Settings.shared.iconsLabelWidthIndex)
        let fontFactor = max(0.8, textWidth("x") / 7)
        let w = 48 + idx * 64 * fontFactor * exp(level / 13)
        return max(iconSize + 4 * Self.pad + 12, w)
    }

    /// Icons: rows of equal cells; each group starts a new row under its header.
    private func layoutIcons(width: CGFloat) -> NSSize {
        let margin = Self.margin, groupH = groupHeaderHeight
        let avail = width - 2 * margin
        columns = max(1, Int(avail / iconsItemWidth()))
        let w = floor(avail / CGFloat(columns))
        let textLines = maxLabelLines + model.props.roles(for: .icons).count
        let h = 3 * Self.pad + iconSize + CGFloat(textLines) * lineHeight + 4
        var y = margin
        var col = 0
        var lastGroup = -2
        for (i, r) in model.rows.enumerated() {
            if r.group != lastGroup && r.group >= 0 {
                if col != 0 { y += h; col = 0 }
                groupHeaderFrames.append(CGRect(x: margin, y: y, width: avail, height: groupH))
                y += groupH
                lastGroup = r.group
            }
            frames[i] = CGRect(x: margin + CGFloat(col) * w, y: y, width: w, height: h)
            col += 1
            if col == columns { col = 0; y += h }
        }
        if col != 0 { y += h }
        return NSSize(width: width, height: max(visibleHeight, y + margin))
    }

    /// Compact: columns as tall as the view, each as wide as its longest (capped) text. Grouped, each group starts a
    /// new column under its header (Dolphin's horizontal group layout).
    private func layoutCompact(width: CGFloat) -> NSSize {
        let rows = model.rows
        let margin = Self.margin, pad = Self.pad, groupH = groupHeaderHeight
        let roles = model.props.roles(for: .compact)
        let h = 2 * pad + max(iconSize, lineHeight * CGFloat(1 + roles.count)) + 2
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let top = margin + groupH
        let availH = max(h, visibleHeight - top - margin - scroller)
        rowsPerColumn = max(1, Int(availH / h))
        let minTextW = 5 * lineHeight
        let maxChars = Settings.shared.compactMaxWidth
        let cap: CGFloat = maxChars == 0 ? 600 : CGFloat(maxChars) * textWidth("x")
        let headerFont = NSFont.systemFont(ofSize: Theme.fontSize, weight: .semibold)
        var x = margin
        var i = 0
        while i < rows.count {
            let group = rows[i].group
            var groupEnd = i
            while groupEnd < rows.count && rows[groupEnd].group == group { groupEnd += 1 }
            let groupX = x
            while i < groupEnd {
                let end = min(groupEnd, i + rowsPerColumn)
                var maxText = minTextW
                for j in i..<end {
                    // As drawn: the shown name, and the roles in the label font.
                    var tw = textWidth(model.displayName(for: rows[j].item))
                    for role in roles { tw = max(tw, textWidth(model.text(for: role, of: rows[j].item))) }
                    maxText = max(maxText, min(tw, cap))
                }
                let colW = ceil(4 * pad + iconSize + 6 + maxText + 10)
                for j in i..<end {
                    frames[j] = CGRect(x: x, y: top + CGFloat(j - i) * h, width: colW, height: h)
                }
                x += colW
                i = end
            }
            if group >= 0, group < model.groups.count {
                // The header is never narrower than its title, so titles of narrow groups don't run into the next one.
                let titleW = ceil((model.groups[group].title as NSString).size(withAttributes: [.font: headerFont]).width) + 16
                x = max(x, groupX + titleW)
                groupHeaderFrames.append(CGRect(x: groupX, y: margin, width: x - groupX - 4, height: groupH))
            }
        }
        return NSSize(width: max(width, x + margin), height: visibleHeight)
    }

    /// Details: one row per item; Name takes the width the other columns leave, unless the user sized it.
    private func layoutDetails(width: CGFloat) -> NSSize {
        detailsRoles = [.name] + model.props.roles(for: .details)
        let h = 2 * Self.pad + max(iconSize, lineHeight) + 2
        let side = Self.sidePadding, groupH = groupHeaderHeight
        let saved = Self.savedColumnWidths
        var fixed: CGFloat = 0
        for r in detailsRoles.dropFirst() {
            let w = saved[r.rawValue] ?? r.defaultColumnWidth
            columnWidths[r] = w
            fixed += w
        }
        columnWidths[.name] = saved[ItemRole.name.rawValue] ?? max(220, width - 2 * side - fixed)
        let total = detailsRoles.reduce(0) { $0 + (columnWidths[$1] ?? 0) }
        var y: CGFloat = 0
        var lastGroup = -2
        for (i, r) in model.rows.enumerated() {
            if r.group != lastGroup && r.group >= 0 {
                groupHeaderFrames.append(CGRect(x: side, y: y, width: total, height: groupH))
                y += groupH
                lastGroup = r.group
            }
            frames[i] = CGRect(x: side, y: y, width: total, height: h)
            y += h
        }
        computeTreeLines()
        return NSSize(width: max(width, total + 2 * side), height: max(visibleHeight, y + 4))
    }

    /// Backward pass: does a later sibling exist at each level (KItemListSiblingsInformation)?
    private func computeTreeLines() {
        let rows = model.rows
        treeLines = Array(repeating: [], count: rows.count)
        var seen: [Bool] = []
        for i in stride(from: rows.count - 1, through: 0, by: -1) {
            let d = rows[i].depth
            if seen.count <= d { seen += Array(repeating: false, count: d + 1 - seen.count) }
            treeLines[i] = Array(seen[0...d])
            seen[d] = true
            if seen.count > d + 1 { seen.removeSubrange((d + 1)...) }
        }
    }

    // MARK: - Details column widths

    static var savedColumnWidths: [String: CGFloat] {
        get { (Settings.store.dictionary(forKey: "columnWidths") as? [String: Double])?.mapValues { CGFloat($0) } ?? [:] }
        set { Settings.store.set(newValue.mapValues { Double($0) }, forKey: "columnWidths") }
    }

    func setColumnWidth(_ w: CGFloat, for role: ItemRole) {
        var saved = Self.savedColumnWidths
        saved[role.rawValue] = max(40, w)
        Self.savedColumnWidths = saved
        relayout()
    }

    /// Width that fits the widest value of a column (header double-click).
    func fittingWidth(for role: ItemRole) -> CGFloat {
        var w = textWidth(role.title) + 36
        for r in model.rows.prefix(2000) {
            var tw = textWidth(role == .name ? model.displayName(for: r.item) : model.text(for: role, of: r.item)) + 18
            if role == .name { tw += iconSize + 20 + CGFloat(r.depth) * Self.indentPerLevel + expanderWidth }
            w = max(w, tw)
        }
        return ceil(min(w, 800))
    }

    func resetColumnWidths() {
        Self.savedColumnWidths = [:]
        relayout()
    }

    // MARK: - Text measurement

    /// Width of a string in the label font (cached).
    func textWidth(_ s: String) -> CGFloat {
        if let w = textWidthCache[s] { return w }
        if textWidthCache.count > 50_000 { textWidthCache = [:] }
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        textWidthCache[s] = w
        return w
    }

    /// Icons-mode label: wrapped to max lines, elided; returns the size actually used (cached).
    func iconsLabel(_ name: String, width: CGFloat, maxLines: Int) -> (label: NSAttributedString, size: CGSize) {
        let key = IconsLabelKey(text: name, width: width, maxLines: maxLines)
        if let hit = iconsLabelCache[key] { return hit }
        if iconsLabelCache.count > 5_000 { iconsLabelCache = [:] }
        let result = makeIconsLabel(name, width: width, maxLines: maxLines)
        iconsLabelCache[key] = result
        return result
    }

    private func makeIconsLabel(_ name: String, width: CGFloat, maxLines: Int) -> (label: NSAttributedString, size: CGSize) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byWordWrapping
        p.lineBreakStrategy = .standard
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: p]
        let bounds = CGSize(width: width, height: 10000)
        let full = NSAttributedString(string: name, attributes: attrs)
        let maxH = CGFloat(maxLines) * lineHeight
        var r = full.boundingRect(with: bounds, options: [.usesLineFragmentOrigin])
        if r.height <= maxH + 1 { return (full, CGSize(width: ceil(r.width), height: ceil(r.height))) }
        // Elide: keep as many characters as fit, with the end of the name after an ellipsis (middle elision).
        let chars = Array(name)
        var lo = 1, hi = chars.count
        var best = NSAttributedString(string: "…", attributes: attrs)
        let tailCount = min(8, chars.count / 3)
        while lo <= hi {
            let mid = (lo + hi) / 2
            let a = NSAttributedString(string: String(chars.prefix(mid)) + "…" + String(chars.suffix(tailCount)), attributes: attrs)
            if a.boundingRect(with: bounds, options: [.usesLineFragmentOrigin]).height <= maxH + 1 { best = a; lo = mid + 1 } else { hi = mid - 1 }
        }
        r = best.boundingRect(with: bounds, options: [.usesLineFragmentOrigin])
        return (best, CGSize(width: ceil(r.width), height: ceil(r.height)))
    }

    // MARK: - Geometry per item

    func iconRect(_ i: Int) -> CGRect {
        let f = frames[i]
        let s = iconSize
        let pad = Self.pad
        switch mode {
        case .icons:
            return CGRect(x: f.midX - s / 2, y: f.minY + 2 * pad, width: s, height: s)
        case .compact:
            return CGRect(x: f.minX + 2 * pad, y: f.midY - s / 2, width: s, height: s)
        case .details:
            let indent = CGFloat(model.rows[i].depth) * Self.indentPerLevel + expanderWidth
            return CGRect(x: f.minX + indent + pad, y: f.midY - s / 2, width: s, height: s)
        }
    }

    var expanderWidth: CGFloat {
        (mode == .details && Settings.shared.detailsExpandableFolders && !model.isSearching) ? 18 : 0
    }

    func expanderRect(_ i: Int) -> CGRect? {
        guard expanderWidth > 0, model.rows[i].item.isBrowsableFolder else { return nil }
        let f = frames[i]
        let x = f.minX + CGFloat(model.rows[i].depth) * Self.indentPerLevel
        return CGRect(x: x, y: f.midY - 8, width: 16, height: 16)
    }

    func nameTextRect(_ i: Int) -> CGRect {
        let f = frames[i]
        let ir = iconRect(i)
        switch mode {
        case .icons:
            return CGRect(x: f.minX + 2 * Self.pad, y: ir.maxY + Self.pad, width: f.width - 4 * Self.pad,
                          height: f.maxY - ir.maxY - Self.pad)
        case .compact:
            return CGRect(x: ir.maxX + 6, y: f.minY, width: f.maxX - ir.maxX - 10, height: f.height)
        case .details:
            let nameW = columnWidths[.name] ?? 200
            return CGRect(x: ir.maxX + 6, y: f.minY, width: f.minX + nameW - ir.maxX - 12, height: f.height)
        }
    }

    /// The rounded "selection rect" (what gets highlighted) for an item, sized to the name as drawn.
    func highlightRect(_ i: Int) -> CGRect {
        let f = frames[i]
        let name = model.displayName(for: model.rows[i].item)
        switch mode {
        case .icons:
            let tr = nameTextRect(i)
            let size = iconsLabel(name, width: tr.width, maxLines: maxLabelLines).size
            let textW = max(size.width, iconSize) + 8
            let rolesH = CGFloat(model.props.roles(for: .icons).count) * lineHeight
            let h = (tr.minY - f.minY) + size.height + rolesH + 4
            let w = min(f.width - 4, max(iconSize + 12, textW))
            return CGRect(x: f.midX - w / 2, y: f.minY + 1, width: w, height: min(f.height - 2, h))
        case .compact:
            let tr = nameTextRect(i)
            let w = min(f.width - 2, (tr.minX - f.minX) + textWidth(name) + 8)
            return CGRect(x: f.minX + 1, y: f.minY + 1, width: w, height: f.height - 2)
        case .details:
            let ir = iconRect(i)
            if Settings.shared.detailsHighlightEntireRow {
                let x = ir.minX - 6
                return CGRect(x: x, y: f.minY + 1, width: f.maxX - x, height: f.height - 2)
            }
            let tr = nameTextRect(i)
            return CGRect(x: ir.minX - 2, y: f.minY + 1, width: tr.minX - ir.minX + textWidth(name) + 8, height: f.height - 2)
        }
    }

    func markerRect(_ i: Int) -> CGRect {
        let ir = iconRect(i)
        let s: CGFloat = mode == .icons ? (iconSize >= 128 ? 22 : (iconSize >= 48 ? 18 : 14)) : 14
        if mode == .icons { return CGRect(x: ir.minX, y: ir.minY, width: s, height: s) }
        return CGRect(x: ir.minX - 1, y: ir.midY - s / 2, width: s, height: s)
    }

    // MARK: - Hit testing

    func index(at p: CGPoint) -> Int? {
        let candidates = candidateIndexes(in: CGRect(origin: p, size: .zero).insetBy(dx: -1, dy: -1))
        switch mode {
        case .details where Settings.shared.detailsClickAnywhere:
            return candidates.first { frames[$0].insetBy(dx: -Self.sidePadding, dy: 0).contains(p) }
        case .details:
            // "Click on icon or name only": the rest of the row is background (rubber band starts there).
            return candidates.first { i in
                let ir = iconRect(i), tr = nameTextRect(i)
                let tw = textWidth(model.displayName(for: model.rows[i].item))
                return CGRect(x: ir.minX - 2, y: frames[i].minY, width: tr.minX - ir.minX + tw + 6, height: frames[i].height).contains(p)
            }
        default:
            return candidates.first { highlightRect($0).contains(p) }
        }
    }

    /// Indexes of items whose cells intersect a rect: a binary search on the sorted axis (y, or x in Compact),
    /// then a scan while cells can still intersect.
    func candidateIndexes(in rect: CGRect) -> [Int] {
        guard !frames.isEmpty else { return [] }
        let horizontal = mode == .compact
        let rowSlack = mode == .details ? -Self.sidePadding : 0
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            let end = horizontal ? frames[mid].maxX : frames[mid].maxY
            if end < (horizontal ? rect.minX : rect.minY) { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int] = []
        var i = lo
        while i < frames.count && (horizontal ? frames[i].minX <= rect.maxX : frames[i].minY <= rect.maxY) {
            if frames[i].insetBy(dx: rowSlack, dy: 0).intersects(rect) { out.append(i) }
            i += 1
        }
        return out
    }

    func rect(for url: URL) -> CGRect? {
        guard let i = model.index(of: url), i < frames.count else { return nil }
        return highlightRect(i)
    }

    func iconScreenRect(for url: URL) -> CGRect? {
        guard let i = model.index(of: url), i < frames.count, let w = window else { return nil }
        return w.convertToScreen(convert(iconRect(i), to: nil))
    }
}
