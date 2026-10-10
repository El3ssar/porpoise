import AppKit
import PorpoiseCore
import PorpoiseServices

extension FileOperationsController {
    /// Dolphin asks what to do on drop unless a modifier was held: Move Here / Copy Here / Link Here / Cancel.
    func handleDrop(_ urls: [URL], onto folder: URL, operation: NSDragOperation, in view: NSView) {
        let urls = urls.filter { $0.standardizedFileURL != folder.standardizedFileURL }
        guard !urls.isEmpty else { return }
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }) { return }
        let w = view.window
        // Dropping into the Trash folder is Move to Trash, as in Finder (put back works, Finder's sound plays).
        if folder.standardizedFileURL == TrashInfo.folder.standardizedFileURL, urls.allSatisfy(\.isFileURL) {
            trash(urls, window: w)
            return
        }
        switch operation {
        case .copy: run(.copy, urls, to: folder, window: w)
        case .move: run(.move, urls, to: folder, window: w)
        case .link: run(.link, urls, to: folder, window: w)
        default:
            let m = NSMenu()
            m.autoenablesItems = false
            let target = DropMenuTarget { [weak self] kind in self?.run(kind, urls, to: folder, window: w) }
            func add(_ title: String, _ key: String, _ icon: String, _ kind: FileOperationKind?) {
                let it = m.addItem(withTitle: title, action: #selector(DropMenuTarget.pick(_:)), keyEquivalent: "")
                it.target = target
                it.representedObject = kind?.rawValue
                it.image = Icons.shared.menuIcon(icon)
                if !key.isEmpty {
                    it.attributedTitle = NSAttributedString(
                        string: title + "\t" + key,
                        attributes: [
                            .font: NSFont.menuFont(ofSize: 0),
                            .paragraphStyle: {
                                let p = NSMutableParagraphStyle(); p.tabStops = [NSTextTab(textAlignment: .right, location: 180)]; return p
                            }(),
                        ])
                }
            }
            // Remote folders can't be checked locally (the provider reports errors); local ones owned by
            // someone else still accept drops, which then ask to authenticate. Only read-only volumes refuse.
            let writable =
                !folder.isFileURL || FileManager.default.isWritableFile(atPath: folder.path)
                || (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
            let remote = !folder.isFileURL || urls.contains { !$0.isFileURL }
            add("Move Here", "⌘", "edit-move", .move)
            add("Copy Here", "⌥", "edit-copy", .copy)
            add("Link Here", "⌘⌥", "edit-link", .link)
            if !writable { m.items.forEach { $0.isEnabled = false } }
            if remote { m.items.last?.isEnabled = false }  // links can't point across remote locations
            m.addItem(.separator())
            add("Cancel", "Esc", "process-stop", nil)
            objc_setAssociatedObject(m, &dropTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
            let loc = view.window?.mouseLocationOutsideOfEventStream ?? .zero
            m.popUp(positioning: nil, at: view.convert(loc, from: nil), in: view)
        }
    }
}

private var dropTargetKey = 0

private final class DropMenuTarget: NSObject {
    let handler: (FileOperationKind) -> Void
    init(_ h: @escaping (FileOperationKind) -> Void) { handler = h }
    @objc func pick(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let k = FileOperationKind(rawValue: raw) { handler(k) }
    }
}
