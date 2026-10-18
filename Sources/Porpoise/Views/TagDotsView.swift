import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// Finder's row of color dots at the bottom of a context menu: click to add or remove a tag.
final class TagDotsView: NSView {
    private(set) var current: Set<String>
    private(set) var isLoading = false
    private let metadataCancellation = DiskCancellation()
    private static let metadataQueue = DispatchQueue(label: "app.porpoise.menu-tags", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let action: (String) -> Void
    private var hover: Int?
    private weak var menuItem: NSMenuItem?

    static func menuItem(for items: [FileItem], action: @escaping (String) -> Void) -> NSMenuItem {
        let it = NSMenuItem()
        let v = view(for: items.map(\.url), action: action)
        v.menuItem = it
        it.view = v
        return it
    }

    /// Menu construction never reads xattrs. Until the answer arrives the dots don't accept edits based on
    /// an unknown intersection; their normal state appears as soon as the metadata is available.
    static func view(
        for urls: [URL], read: @escaping @Sendable (URL) -> [FinderTags.Tag] = { FinderTags.read($0) },
        action: @escaping (String) -> Void
    ) -> TagDotsView {
        let view = TagDotsView(current: [], action: action)
        view.isLoading = true
        view.toolTip = "Reading tags…"
        view.alphaValue = 0.5
        let cancellation = view.metadataCancellation
        metadataQueue.async { [weak view] in
            let tags = commonTags(urls, read: read, cancellation: cancellation)
            DispatchQueue.main.async { [weak view] in
                guard let view, !cancellation.isCancelled else { return }
                view.current = tags
                view.isLoading = false
                view.alphaValue = 1
                view.toolTip = nil
                view.needsDisplay = true
            }
        }
        return view
    }

    /// Stop as soon as no tag can be common to every item; don't materialize a set for every selected file.
    nonisolated private static func commonTags(
        _ urls: [URL], read: (URL) -> [FinderTags.Tag], cancellation: DiskCancellation
    ) -> Set<String> {
        var common: Set<String>?
        for url in urls {
            guard !cancellation.isCancelled else { return [] }
            let tags = autoreleasepool { Set(read(url).map(\.name)) }
            common = common.map { $0.intersection(tags) } ?? tags
            if common?.isEmpty == true { break }
        }
        return common ?? []
    }

    init(current: Set<String>, action: @escaping (String) -> Void) {
        self.current = current
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: 230, height: 30))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tags")
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { metadataCancellation.cancel() }

    private func dotRect(_ i: Int) -> CGRect { CGRect(x: 20 + CGFloat(i) * 28, y: 6, width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, t) in FinderTags.standard.enumerated() {
            let r = dotRect(i).insetBy(dx: hover == i ? -1.5 : 0, dy: hover == i ? -1.5 : 0)
            FinderTags.color(t.color)?.setFill()
            NSBezierPath(ovalIn: r).fill()
            if current.contains(t.name) {
                // Check mark when every selected item has the tag; hovering shows ✕ to remove it.
                let s = (hover == i ? "✕" : "✓") as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
                let sz = s.size(withAttributes: a)
                s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
            } else if hover == i {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 1.5; p.stroke()
            }
        }
    }

    private func index(at p: CGPoint) -> Int? { FinderTags.standard.indices.first { dotRect($0).insetBy(dx: -5, dy: -5).contains(p) } }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
        toolTip =
            isLoading
            ? "Reading tags…"
            : h.map { (current.contains(FinderTags.standard[$0].name) ? "Remove tag “" : "Add tag “") + FinderTags.standard[$0].name + "”" }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard !isLoading, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let name = FinderTags.standard[i].name
        action(name)
        if current.contains(name) { current.remove(name) } else { current.insert(name) }
        needsDisplay = true
        menuItem?.menu?.cancelTracking()
    }
}
