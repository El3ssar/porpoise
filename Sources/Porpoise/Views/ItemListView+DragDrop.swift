import AppKit
import PorpoiseCore

/// Items beyond this many are dragged without their own drag image.
private let maxDragImages = 200
/// Spring-loaded folders: hovering a folder this long during a drag opens it.
private let dragOpenDelay: TimeInterval = 0.75

// MARK: - Drag source

extension ItemListView: NSDraggingSource {
    func startDrag(from i: Int, event: NSEvent) {
        let url = model.rows[i].item.url
        if !model.selection.contains(url) { model.selection = [url] }
        let items = model.rows.enumerated().filter { model.selection.contains($0.element.item.url) }
        let allURLs = items.map(\.element.item.url)
        var dragItems: [NSDraggingItem] = []
        for (n, (idx, r)) in items.enumerated() {
            // Like Finder: a file URL per item, plus the classic file list on the first one for older apps.
            let di = NSDraggingItem(pasteboardWriter: FileDragWriter(url: r.item.url, allURLs: n == 0 ? allURLs : nil))
            if n < maxDragImages {
                di.setDraggingFrame(iconRect(idx < frames.count ? idx : i), contents: Icons.shared.image(for: r.item, size: iconSize))
            }
            dragItems.append(di)
        }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // .delete lets items be dropped on the Trash in the Dock (we then move them to the Trash).
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation == .delete else { return }
        let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { FileOperationsController.shared.trash(urls, window: window, sound: .dragToTrash) }
    }
}

// MARK: - Drop target

extension ItemListView {
    /// The folder a drop at `p` goes into: the folder item under it, or the shown location.
    private func dropFolder(at p: CGPoint) -> (URL, Int?) {
        if let i = index(at: p), model.rows[i].item.isBrowsableFolder {
            let u = model.rows[i].item.url
            // A share in Network (smb://…) is no folder to copy into until it is mounted.
            if u.isFileURL || RemoteFS.isRemote(u) { return (u, i) }
        }
        return (model.location, nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !model.isSearching else { return [] }
        let urls = draggedURLs(sender)
        let (folder, idx) = dropFolder(at: convert(sender.draggingLocation, from: nil))
        let target = folder.standardizedFileURL
        // Nothing droppable, a folder onto itself, or items onto the folder they are already in.
        let sameFolder = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == target }
        // Recent Files, Tags, Smart Folders and Network list items from elsewhere: only their folders take drops.
        let virtualTarget = idx == nil && !folder.isFileURL && !RemoteFS.isRemote(folder)
        if urls.isEmpty || virtualTarget || urls.contains(where: { $0.standardizedFileURL == target }) || (sameFolder && idx == nil) {
            setDropTarget(nil, background: false)
            return []
        }
        setDropTarget(idx, background: idx == nil)
        if idx != nil && Settings.shared.openFoldersDuringDrag && dragOpenTimer == nil { scheduleDragOpen() }
        return Self.operation(for: sender)
    }

    /// Opens the folder under the drag after a pause (in all run loop modes: the drag runs an event-tracking loop).
    private func scheduleDragOpen() {
        let t = Timer(timeInterval: dragOpenDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dragOpenTimer = nil
            guard let i = self.dropTargetIndex, i < self.model.rows.count, self.model.rows[i].item.isBrowsableFolder else { return }
            let folder = self.model.rows[i].item
            // The rows are about to change: the index must not mark an item of the new folder.
            self.setDropTarget(nil, background: false)
            self.delegate?.itemList(self, open: [folder], inNewTab: false)
        }
        dragOpenTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let mods = NSEvent.modifierFlags
        let mask = sender.draggingSourceOperationMask
        if mods.contains(.command) && mods.contains(.option) { return .link }
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .move }
        // No modifier: Dolphin asks with a menu; show the generic cursor.
        return mask.contains(.generic) ? .generic : (mask.contains(.move) ? .move : .copy)
    }

    private func setDropTarget(_ i: Int?, background: Bool) {
        if i != dropTargetIndex { dragOpenTimer?.invalidate(); dragOpenTimer = nil }
        if i != dropTargetIndex || background != dropOnBackground {
            dropTargetIndex = i
            dropOnBackground = background
            needsDisplay = true
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(nil, background: false) }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        draggedURLCache = nil
        setDropTarget(nil, background: false)
    }

    /// Local files, plus remote items dragged inside the app (sftp://, ftp://, adb://); read once per drag.
    private func draggedURLs(_ sender: NSDraggingInfo) -> [URL] {
        if let c = draggedURLCache, c.sequence == sender.draggingSequenceNumber { return c.urls }
        let urls = ((sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [])
            .filter { $0.isFileURL || RemoteFS.isRemote($0) }
        draggedURLCache = (sender.draggingSequenceNumber, urls)
        return urls
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let (folder, _) = dropFolder(at: convert(sender.draggingLocation, from: nil))
        let urls = draggedURLs(sender)
        setDropTarget(nil, background: false)
        draggedURLCache = nil
        guard !urls.isEmpty else { return false }
        delegate?.itemList(self, drop: urls, onto: folder, operation: Self.operation(for: sender), event: nil)
        return true
    }
}

/// Drag pasteboard data for one file: its file URL, and on the first item also the classic
/// NSFilenamesPboardType list that Chrome, Electron, Qt and Java apps read (Finder provides both).
final class FileDragWriter: NSObject, NSPasteboardWriting {
    static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    let url: URL
    let allURLs: [URL]?

    init(url: URL, allURLs: [URL]?) { self.url = url; self.allURLs = allURLs }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        guard url.isFileURL else { return [.URL] }
        return allURLs != nil ? [.fileURL, Self.filenames] : [.fileURL]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL: return url.absoluteString
        case Self.filenames: return allURLs?.filter(\.isFileURL).map(\.path)
        default: return nil
        }
    }
}
