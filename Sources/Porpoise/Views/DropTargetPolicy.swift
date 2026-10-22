import AppKit
import PorpoiseCore
import PorpoiseServices

/// What a drop does, the same wherever items are dropped (an item view, a tab, a crumb, a place): which dragged items
/// count, the operation (the cursor shows the one the drop then does), and whether a folder takes them. Each target
/// keeps only its hit-testing and highlight.
enum DropTargetPolicy {
    /// What a drop target registers for: files, and items on servers and cloud accounts dragged inside the app.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL]

    nonisolated(unsafe) private static var cache: (sequence: Int, urls: [URL])?

    /// The dragged items that can be dropped: files on this Mac, and items on servers and cloud accounts (sftp://,
    /// ftp://, adb://, Drive, Dropbox). Read once per drag.
    static func urls(_ sender: NSDraggingInfo) -> [URL] {
        if let c = cache, c.sequence == sender.draggingSequenceNumber { return c.urls }
        let urls = urls(on: sender.draggingPasteboard)
        cache = (sender.draggingSequenceNumber, urls)
        return urls
    }

    static func urls(on pasteboard: NSPasteboard) -> [URL] {
        ((pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []).filter { $0.isFileURL || RemoteFS.isRemote($0) }
    }

    /// The modifier keys held now (the live keyboard). Tests replace it: what someone holds down on the Mac, or keys
    /// another process injects, must not change what they see.
    nonisolated(unsafe) static var heldModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    /// The drop's operation, for the cursor and for the drop alike: ⌥ copies, ⌘ moves, ⌘⌥ links; without a modifier
    /// the drop asks with a menu (Dolphin), when the source allows it, else it moves or copies as the source allows.
    static func operation(for sender: NSDraggingInfo, modifiers mods: NSEvent.ModifierFlags = heldModifiers()) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        if mods.contains(.command) && mods.contains(.option) { return .link }
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .move }
        return mask.contains(.generic) ? .generic : (mask.contains(.move) ? .move : .copy)
    }

    /// Whether `folder` takes `urls`: a folder with a hierarchy (not Recent Files, Tags, Network…), not a cloud folder
    /// that's view-only (or Shared with me itself), and not one of the items, nor the folder they're all in already.
    static func accepts(_ urls: [URL], into folder: URL) -> Bool {
        guard !urls.isEmpty, LocationKind.of(folder).acceptsDrops else { return false }
        if PlacesModel.isCloud(folder) && CloudAccounts.shared.denial(.addItems, folder: folder) != nil { return false }
        let target = identity(folder)
        if urls.contains(where: { identity($0) == target }) { return false }
        return !urls.allSatisfy { identity($0.deletingLastPathComponent()) == target }
    }

    /// A location as compared here: with or without its trailing slash it's the same folder.
    private static func identity(_ url: URL) -> String {
        var s = url.standardizedFileURL.absoluteString
        while s.hasSuffix("/") && !s.hasSuffix("://") && s.count > 1 { s.removeLast() }
        return s
    }

    /// A drag ended or was dropped: the next one is read afresh.
    static func dragEnded() { cache = nil }
}

/// Spring-loading: opens what a drag rests on after a pause. It runs in every run loop mode: a drag inside the app
/// runs an event-tracking loop, where a default-mode timer would never fire.
final class SpringLoader {
    /// How long a drag rests on a folder or a tab before it opens.
    static let delay: TimeInterval = 0.75
    private let delay: TimeInterval
    private var timer: Timer?
    private(set) var target: AnyHashable?

    init(delay: TimeInterval = SpringLoader.delay) { self.delay = delay }

    /// The drag is over `target` now (nil: over nothing that opens): a new target starts the pause over, and `open`
    /// runs once it has passed. Drags send updates while the pointer rests, which leave a running pause alone.
    func hover(_ target: AnyHashable?, open: @escaping () -> Void) {
        guard target != self.target else { return }
        cancel()
        self.target = target
        guard target != nil else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            open()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    deinit { timer?.invalidate() }
}

/// Dragging items out of a view (the item views, the app library): a file URL per item plus the classic file list,
/// copy/move/link inside the app, and onto the Dock's Trash to delete.
enum FileDragSource {
    /// The dragging items for `urls`, each with its frame and image when `look` gives one (many items drag without).
    static func items(_ urls: [URL], look: (Int) -> (frame: CGRect, image: NSImage)?) -> [NSDraggingItem] {
        urls.enumerated().map { n, url in
            // Like Finder: a file URL per item, plus the classic file list on the first one for older apps.
            let item = NSDraggingItem(pasteboardWriter: FileDragWriter(url: url, allURLs: n == 0 ? urls : nil))
            if let l = look(n) { item.setDraggingFrame(l.frame, contents: l.image) }
            return item
        }
    }

    /// Starts the drag from `view`, the items flying back if it's cancelled.
    static func begin(_ items: [NSDraggingItem], from view: NSView & NSDraggingSource, event: NSEvent) {
        guard !items.isEmpty else { return }
        let session = view.beginDraggingSession(with: items, event: event, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    static func mask(for context: NSDraggingContext) -> NSDragOperation {
        // .delete lets items be dropped on the Trash in the Dock (they're then moved to the Trash).
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .link, .generic]
    }

    /// The drag is over: dropped on the Dock's Trash, its files go to the Trash.
    static func ended(_ session: NSDraggingSession, operation: NSDragOperation, window: NSWindow?) {
        guard operation == .delete else { return }
        let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { FileOperationsController.shared.trash(urls, window: window, sound: .dragToTrash) }
    }
}
