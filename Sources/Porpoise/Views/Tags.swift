import AppKit
import PorpoiseCore
import PorpoiseServices

/// Finder tags: names plus Finder's color index, read from the `_kMDItemUserTags` extended attribute
/// ("Name\n6"), which is where Finder keeps each tag's color.
enum FinderTags {
    struct Tag: Equatable { var name: String; var color: Int }

    /// Finder's standard tags with their label color numbers.
    static let standard: [Tag] = [
        Tag(name: "Red", color: 6), Tag(name: "Orange", color: 7), Tag(name: "Yellow", color: 5), Tag(name: "Green", color: 2),
        Tag(name: "Blue", color: 4), Tag(name: "Purple", color: 3), Tag(name: "Gray", color: 1),
    ]

    static func color(_ index: Int) -> NSColor? {
        switch index {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }

    static func read(_ url: URL) -> [Tag] {
        guard url.isFileURL else { return [] }
        let name = "com.apple.metadata:_kMDItemUserTags"
        let len = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let got = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        guard got > 0 else { return [] }
        data.count = got   // the attribute may have shrunk between the two calls
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1)
            let n = String(parts.first ?? "")
            let c = parts.count > 1 ? Int(parts[1]) ?? 0 : (standard.first { $0.name == n }?.color ?? 0)
            return Tag(name: n, color: c)
        }
    }

    /// Writes tag names; macOS assigns the standard colors itself.
    static func set(_ names: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    /// Overlapping dots, as Finder draws them next to names.
    static func drawDots(_ tags: [Tag], at origin: CGPoint, diameter d: CGFloat, background: NSColor) {
        let shown = tags.prefix(3)
        for (i, t) in shown.enumerated().reversed() {
            let r = CGRect(x: origin.x + CGFloat(i) * d * 0.55, y: origin.y, width: d, height: d)
            let path = NSBezierPath(ovalIn: r)
            background.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
            if let c = color(t.color) {
                c.setFill(); path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke(); path.lineWidth = 1.2
                NSBezierPath(ovalIn: r.insetBy(dx: 0.6, dy: 0.6)).stroke()
            }
        }
    }

    static func dotsWidth(_ count: Int, diameter d: CGFloat) -> CGFloat {
        count == 0 ? 0 : d + CGFloat(min(count, 3) - 1) * d * 0.55
    }

    static func url(for tag: String) -> URL { URL(string: "tags:/" + (tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag))! }
}

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

/// Files carrying a tag (the sidebar's Tags section), found with Spotlight.
final class MetadataListQuery: NSObject {
    private let query = NSMetadataQuery()
    private let done: ([FileItem]) -> Void

    init(predicate: NSPredicate, scopes: [Any] = [NSMetadataQueryLocalComputerScope], done: @escaping ([FileItem]) -> Void) {
        self.done = done
        super.init()
        query.predicate = predicate
        query.searchScopes = scopes
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    deinit {
        // Replaced before it finished gathering (the user moved on): stop searching.
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    static func tagged(_ tag: String, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery {
        MetadataListQuery(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), done: done)
    }

    /// Finder Smart Folder (.savedSearch): its raw Spotlight query and scopes.
    static func smartFolder(_ file: URL, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery? {
        guard let d = NSDictionary(contentsOf: file), let raw = d["RawQuery"] as? String,
              let pred = NSPredicate(fromMetadataQueryString: raw) else { return nil }
        let crit = d["SearchCriteria"] as? [String: Any]
        let scopes: [Any] = ((crit?["FXScopeArrayOfPaths"] as? [String]) ?? []).map { s -> Any in
            switch s {
            case "kMDQueryScopeHome": return NSMetadataQueryUserHomeScope
            case "kMDQueryScopeComputer": return NSMetadataQueryLocalComputerScope
            case "kMDQueryScopeAllIndexed": return NSMetadataQueryIndexedLocalComputerScope
            default: return URL(fileURLWithPath: s)
            }
        }
        return MetadataListQuery(predicate: pred, scopes: scopes.isEmpty ? [NSMetadataQueryLocalComputerScope] : scopes, done: done)
    }

    @objc private func gathered() {
        query.stop()
        var items: [FileItem] = []
        for i in 0..<min(query.resultCount, 2000) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let it = FileItem.load(URL(fileURLWithPath: p)) else { continue }
            items.append(it)
        }
        NotificationCenter.default.removeObserver(self)
        done(items)
    }
}
