import AppKit
import PorpoiseCore
import PorpoiseServices

extension PlacesPanel {
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

    func header(at i: Int?) -> PlaceSection? {
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
}
