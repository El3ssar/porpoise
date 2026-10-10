import AppKit
import PorpoiseCore
import PorpoiseServices

/// Finder's row of color dots at the bottom of a context menu: click to add or remove a tag.
final class TagDotsView: NSView {
    private var current: Set<String>
    private let action: (String) -> Void
    private var hover: Int?
    private weak var menuItem: NSMenuItem?

    static func menuItem(for items: [FileItem], action: @escaping (String) -> Void) -> NSMenuItem {
        let it = NSMenuItem()
        let v = TagDotsView(current: commonTags(items.map(\.url)), action: action)
        v.menuItem = it
        it.view = v
        return it
    }

    static func view(for urls: [URL], action: @escaping (String) -> Void) -> TagDotsView {
        TagDotsView(current: commonTags(urls), action: action)
    }

    /// Tag names every one of the items carries (they get a check mark).
    private static func commonTags(_ urls: [URL]) -> Set<String> {
        let present = urls.map { Set(FinderTags.read($0).map(\.name)) }
        return present.dropFirst().reduce(present.first ?? []) { $0.intersection($1) }
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
        toolTip = h.map { (current.contains(FinderTags.standard[$0].name) ? "Remove tag “" : "Add tag “") + FinderTags.standard[$0].name + "”" }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let name = FinderTags.standard[i].name
        action(name)
        if current.contains(name) { current.remove(name) } else { current.insert(name) }
        needsDisplay = true
        menuItem?.menu?.cancelTracking()
    }
}
