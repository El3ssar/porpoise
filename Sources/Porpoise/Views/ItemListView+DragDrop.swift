import AppKit
import PorpoiseCore
import PorpoiseServices

/// Items beyond this many are dragged without their own drag image.
private let maxDragImages = 200

// MARK: - Drag source

extension ItemListView: NSDraggingSource {
    func startDrag(from i: Int, event: NSEvent) {
        let url = model.rows[i].item.url
        if !model.selection.contains(url) { model.selection = [url] }
        let items = model.rows.enumerated().filter { model.selection.contains($0.element.item.url) }
        let drag = FileDragSource.items(items.map(\.element.item.url)) { n in
            guard n < maxDragImages else { return nil }
            let (idx, r) = items[n]
            return (iconRect(idx < frames.count ? idx : i), Icons.shared.image(for: r.item, size: iconSize))
        }
        FileDragSource.begin(drag, from: self, event: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDragSource.mask(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        FileDragSource.ended(session, operation: operation, window: window)
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
        let (folder, idx) = dropFolder(at: convert(sender.draggingLocation, from: nil))
        guard DropTargetPolicy.accepts(DropTargetPolicy.urls(sender), into: folder) else {
            setDropTarget(nil, background: false)
            return []
        }
        setDropTarget(idx, background: idx == nil)
        // Resting on a folder opens it (Settings › Open folders during drag).
        springLoader.hover(Settings.shared.openFoldersDuringDrag ? idx : nil) { [weak self] in
            guard let self, let i = self.dropTargetIndex, i < self.model.rows.count, self.model.rows[i].item.isBrowsableFolder else { return }
            let folder = self.model.rows[i].item
            // The rows are about to change: the index must not mark an item of the new folder.
            self.setDropTarget(nil, background: false)
            self.delegate?.itemList(self, open: [folder], inNewTab: false)
        }
        return DropTargetPolicy.operation(for: sender)
    }

    private func setDropTarget(_ i: Int?, background: Bool) {
        if i == nil { springLoader.cancel() }
        if i != dropTargetIndex || background != dropOnBackground {
            dropTargetIndex = i
            dropOnBackground = background
            needsDisplay = true
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(nil, background: false) }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DropTargetPolicy.dragEnded()
        setDropTarget(nil, background: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let (folder, _) = dropFolder(at: convert(sender.draggingLocation, from: nil))
        let urls = DropTargetPolicy.urls(sender)
        setDropTarget(nil, background: false)
        DropTargetPolicy.dragEnded()
        guard !urls.isEmpty else { return false }
        delegate?.itemList(self, drop: urls, onto: folder, operation: DropTargetPolicy.operation(for: sender), event: nil)
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
