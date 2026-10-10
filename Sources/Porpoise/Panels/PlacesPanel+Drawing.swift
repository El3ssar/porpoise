import AppKit
import PorpoiseCore
import PorpoiseServices

extension PlacesPanel {
    // MARK: Capacity and trash state

    func refreshCapacities() {
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
                    let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
                else { continue }
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.windowTextInactive.withAlphaComponent(hovered ? 0.85 : 0.62),
        ]
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
        c.draw(
            in: CGRect(x: -c.size.width / 2, y: -c.size.height / 2, width: c.size.width, height: c.size.height), from: .zero,
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font, .foregroundColor: Theme.windowText.withAlphaComponent(alpha), .paragraphStyle: p,
        ]
        let title = e.hidden ? e.title + " (hidden)" : e.title
        (title as NSString).draw(in: CGRect(x: tx, y: ty, width: r.width - tx - 14 - ejectW, height: lh + 3), withAttributes: attrs)

        if e.isVolume, let c = capacities[e.url], c.total > 0 {
            drawCapacityBar(c, in: CGRect(x: tx, y: ty + lh + 4, width: r.width - tx - 16 - ejectW, height: 3))
        }
        if e.isEjectable, let img = Icons.shared.image("media-eject", size: Metrics.ejectIconSize) {
            let s = Metrics.ejectIconSize
            img.draw(
                in: CGRect(x: r.maxX - Metrics.ejectIconRightOffset, y: r.minY + (rowHeight - s) / 2, width: s, height: s),
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
        if entry(at: ins) != nil {
            y = rows[ins].y
        } else if entry(at: ins - 1) != nil {
            y = rows[ins - 1].y + rows[ins - 1].height
        } else if entry(at: ins + 1) != nil {
            y = rows[ins + 1].y
        } else {
            return
        }
        Theme.selectionAlternate.setFill()
        NSBezierPath(roundedRect: CGRect(x: 12, y: y - 1, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
    }
}
