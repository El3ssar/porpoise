import AppKit
import PorpoiseCore
import PorpoiseServices

extension PlacesPanel {
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
                PlacesModel.shared.canMove(moving, before: d.target, endOf: d.section)
            else { return setDrop(nil, insert: nil) }
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
