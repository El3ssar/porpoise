import AppKit
import PorpoiseCore
import PorpoiseServices

protocol BreadcrumbDelegate: AnyObject {
    func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool)
    func breadcrumbActivated(_ b: BreadcrumbView)
    func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL, operation: NSDragOperation)
}

/// KDE's KUrlNavigator: breadcrumb buttons with subfolder arrows, switching to an editable path field.
final class BreadcrumbView: NSView, NSTextFieldDelegate {
    weak var delegate: BreadcrumbDelegate?
    var url: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet {
            guard url != oldValue else { return }
            rebuild()
            // Editable location bar: the field shows where the view is now.
            if isEditing { field?.stringValue = editText }
        }
    }
    var isActive = true { didSet { needsDisplay = true } }
    var missingTail = false { didSet { needsDisplay = true } }
    var preferredAncestorName: String? { didSet { if preferredAncestorName != oldValue { rebuild() } } }
    var showPlacesButton = false { didSet { rebuild() } }
    var places: [PlaceEntry] = [] { didSet { rebuild() } }
    private(set) var isEditing = false

    private struct Segment {
        enum Kind { case placesButton, rootArrow, crumb(URL, String, Bool), arrow(URL), more([URL]) }
        let kind: Kind
        var rect: CGRect = .zero
    }

    private var segments: [Segment] = []

    /// Every folder of the path, from the root place down, also those collapsed into "…" or left out of a narrow field.
    private var trail: [(url: URL, title: String)] = []

    /// VoiceOver: the path's folders, each pressable, including those that don't fit (at the "…", or at the one
    /// folder a narrow field shows). The arrows and buttons are reachable through the menus.
    override func accessibilityChildren() -> [Any]? {
        if isEditing { return super.accessibilityChildren() }
        return trail.map { crumb in
            let u = crumb.url
            return AccessibleRegion(
                in: self, role: .button, label: crumb.title,
                frame: { [weak self] in self?.accessibilityFrame(of: u) ?? .zero },
                press: { [weak self] in if let self { self.delegate?.breadcrumb(self, navigateTo: u, newTab: false) } })
        }
    }

    /// Where a folder of the path is drawn: its crumb, the "…" holding it, or else the first thing shown.
    private func accessibilityFrame(of u: URL) -> CGRect {
        let shown = segments.first {
            switch $0.kind {
            case .crumb(let c, _, _): return c == u
            case .more(let urls): return urls.contains(u)
            default: return false
            }
        }
        return
            (shown
            ?? segments.first {
                if case .crumb = $0.kind { return true }; return false
            })?.rect ?? .zero
    }

    // MARK: Keyboard (Full Keyboard Access)

    /// The segment that has keyboard focus: Tab reaches the path, ←/→ move along it, Space or Return opens the folder
    /// (or the "…" menu).
    private var focused: Int? {
        didSet {
            if focused != oldValue { noteFocusRingMaskChanged(); needsDisplay = true }
        }
    }
    private var focusable: [Int] {
        segments.indices.filter {
            switch segments[$0].kind {
            case .crumb, .more: return true
            default: return false
            }
        }
    }

    override var acceptsFirstResponder: Bool { KeyboardAccess.isFull() && !isEditing }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        focused = focusable.last
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = nil
        return true
    }

    override var focusRingMaskBounds: NSRect { focused.map { i in i < segments.count ? segments[i].rect : .zero } ?? .zero }
    override func drawFocusRingMask() {
        guard let i = focused, i < segments.count else { return }
        NSBezierPath(roundedRect: segments[i].rect.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        let order = focusable
        guard !isEditing, let i = focused, let at = order.firstIndex(of: i) else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 123: focused = order[max(0, at - 1)]  // ←
        case 124: focused = order[min(order.count - 1, at + 1)]  // →
        case 49, 36, 76: activateSegment(i)  // Space, Return, Enter
        default: super.keyDown(with: event)
        }
    }

    private func activateSegment(_ i: Int) {
        guard i < segments.count else { return }
        switch segments[i].kind {
        case .crumb(let u, _, _): delegate?.breadcrumb(self, navigateTo: u, newTab: false)
        case .more(let urls): showMenu(urls.map { ($0, $0.folderName) }, at: segments[i].rect)
        default: break
        }
    }
    private var hover: Int?
    private var pressed: Int?
    private var dropHover: Int?
    private var field: PathField?
    private var tracking: NSTrackingArea?
    /// Opens an arrow's subfolder menu when a drag rests on it, sooner than a folder opens.
    private let arrowSpringLoader = SpringLoader(delay: 0.3)
    private var completion = CompletionSource()

    private static let maxMenuEntries = 400

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropTargetPolicy.types)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Location")
        // A cloud folder's ancestry and names can arrive after the folder itself.
        cloudObserver = NotificationCenter.default.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, PlacesModel.isCloud(self.url), !self.isEditing else { return }
                self.rebuild()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { cloudObserver.map(NotificationCenter.default.removeObserver) }

    private var cloudObserver: NSObjectProtocol?

    // MARK: Model

    /// The place that the breadcrumb starts at (longest matching prefix), unless "show full path".
    private func rootPlace() -> PlaceEntry? {
        guard !Settings.shared.showFullPathInLocation else { return nil }
        let p = url.standardizedFileURL.path
        return places.filter { $0.url.isFileURL && $0.url.path != "/" && (p == $0.url.path || p.hasPrefix($0.url.path + "/")) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Re-applies settings (full path, places) without changing the URL.
    func refresh() { rebuild() }

    private func rebuild() {
        var segs: [Segment] = []
        if showPlacesButton { segs.append(Segment(kind: .placesButton)) }
        segs.append(Segment(kind: .rootArrow))
        let crumbs = url.isFileURL ? localCrumbs() : remoteCrumbs()
        // Virtual locations (network:, recent:) have no subfolder menus.
        let arrows = LocationKind.of(url).hasHierarchy
        trail = crumbs
        for (i, c) in crumbs.enumerated() {
            let last = i == crumbs.count - 1
            segs.append(Segment(kind: .crumb(c.url, c.title, last)))
            if !last && arrows { segs.append(Segment(kind: .arrow(c.url))) }
        }
        segments = segs
        hover = nil
        layoutSegments()
        // Keyboard focus stays on the path: on the folder now shown.
        if focused != nil { focused = focusable.last }
        needsDisplay = true
        setAccessibilityValue(LocationNaming.address(for: url))
    }

    /// Crumbs from the root place (or the volume) down to the folder.
    private func localCrumbs() -> [(url: URL, title: String)] {
        var crumbs: [(url: URL, title: String)] = []
        var u = url.standardizedFileURL
        let root = rootPlace()
        while true {
            if let r = root, u.path == r.url.path { crumbs.append((u, r.title)); break }
            if u.path == "/" { crumbs.append((u, volumeName(for: u))); break }
            crumbs.append((u, u.lastPathComponent))
            u = u.deletingLastPathComponent()
        }
        return crumbs.reversed()
    }

    /// Remote/virtual locations: a "user@host" (or location name) root crumb, then the path components.
    private func remoteCrumbs() -> [(url: URL, title: String)] {
        if LocationKind.of(url).isVirtual { return [(url, LocationNaming.title(for: url))] }
        if PlacesModel.isCloud(url) { return cloudCrumbs() }
        let chain = RemoteFS.pathAncestors(of: url) + [url]
        return chain.map { (url: $0, title: LocationNaming.name(for: $0)) }
    }

    /// Cloud folders: the account, then its row (My Drive, Files, Shared with me…), then each folder by name, as
    /// the service tells its ancestry.
    func cloudCrumbs() -> [(url: URL, title: String)] {
        let accounts = CloudAccounts.shared
        let account = accounts.account(for: url)
        let accountTitle = account.map { accounts.title($0.id) } ?? accounts.providerTitle(for: url)
        guard url.pathComponents.contains(where: { $0 != "/" }) else { return [(url, accountTitle)] }
        // The folder itself keeps its query (resource key, shared drive, namespace).
        let crumbs = (accounts.ancestors(of: url) + [url]).map { (url: $0, title: $0.folderName) }
        // The account's crumb opens its first row.
        let root = account.flatMap { a in CloudAccounts.shared.url(a.id, root: CloudAccounts.shared.availableRows(a.id).first ?? .myDrive) }
        return [(root ?? crumbs.first?.url ?? url, accountTitle)] + crumbs
    }

    private func volumeName(for u: URL) -> String {
        (try? u.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/"
    }

    private let crumbFont = Theme.font
    private let crumbBoldFont = NSFont.systemFont(ofSize: Theme.fontSize, weight: .bold)

    private func width(of s: Segment) -> CGFloat {
        switch s.kind {
        case .placesButton: return 26
        case .rootArrow: return 24
        case .arrow: return 18
        case .more: return 22
        case .crumb(_, let title, let last):
            return ceil((title as NSString).size(withAttributes: [.font: last ? crumbBoldFont : crumbFont]).width) + 10
        }
    }

    private func layoutSegments() {
        let h = bounds.height
        if bounds.width < 200,
            let last = segments.last(where: {
                if case .crumb(_, _, true) = $0.kind { return true }; return false
            })
        {
            segments = [last]; segments[0].rect = bounds.insetBy(dx: 5, dy: 5)
            return
        }
        var x: CGFloat = 10
        let available = bounds.width - 40
        // Collapse leading crumbs into a "more" menu when the path doesn't fit.
        var segs = segments
        var total = segs.reduce(CGFloat(6)) { $0 + width(of: $1) }
        var hidden: [URL] = []
        while total > available {
            guard
                let i = segs.firstIndex(where: {
                    if case .crumb(_, let title, let last) = $0.kind { return !last && title != preferredAncestorName }; return false
                }),
                case .crumb(let u, _, _) = segs[i].kind
            else { break }
            hidden.append(u)
            total -= width(of: segs[i])
            segs.remove(at: i)
            if i < segs.count, case .arrow = segs[i].kind { total -= width(of: segs[i]); segs.remove(at: i) }
        }
        if !hidden.isEmpty,
            let r = segs.firstIndex(where: {
                if case .rootArrow = $0.kind { return true }; return false
            })
        {
            segs.insert(Segment(kind: .more(hidden)), at: r + 1)
        }
        for i in segs.indices {
            let w = width(of: segs[i])
            segs[i].rect = CGRect(x: x, y: 5, width: w, height: h - 10)
            x += w
        }
        segments = segs
    }

    override func layout() {
        super.layout()
        if !isEditing { rebuildIfNeeded() }
        field?.frame = fieldFrame
    }

    private var lastLayoutWidth: CGFloat = 0
    private func rebuildIfNeeded() {
        if lastLayoutWidth != bounds.width { lastLayoutWidth = bounds.width; rebuild() }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        // Mac-style field: soft filled capsule on the toolbar material; a focus ring while editing.
        // The glass capsule behind provides the field; editing shows a focused text field inside it.
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: (bounds.height - 4) / 2, yRadius: (bounds.height - 4) / 2)
        if isEditing {
            Theme.viewBackground.withAlphaComponent(0.85).setFill()
            frame.fill()
            Theme.selectionAlternate.withAlphaComponent(0.7).setStroke()
            frame.lineWidth = 1.5
            frame.stroke()
            return
        }
        if fieldHover && hover == nil {
            Theme.windowText.withAlphaComponent(0.04).setFill()
            frame.fill()
        }
        let textColor = isActive ? Theme.windowText : Theme.windowTextInactive.withAlphaComponent(0.7)

        if bounds.width < 200 {
            let title = preferredAncestorName.map { "\($0) › \(url.folderName)" } ?? url.folderName
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let font = NSFont.systemFont(ofSize: preferredAncestorName == nil ? Theme.fontSize : 11, weight: .medium)
            (title as NSString).draw(
                in: CGRect(x: 5, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 10), height: 18),
                withAttributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: style])
            return
        }
        for (i, s) in segments.enumerated() {
            let r = s.rect
            if hover == i || pressed == i || dropHover == i {
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6)
                (pressed == i || dropHover == i ? Theme.selection.withAlphaComponent(0.55) : Theme.windowText.withAlphaComponent(0.10)).setFill()
                p.fill()
            }
            switch s.kind {
            case .placesButton:
                Icons.shared.image("folder", size: 16)?.draw(
                    in: CGRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case .rootArrow:
                // Where the path starts (home, the disk, a server) instead of a lone chevron; its menu is unchanged.
                Icons.shared.image(rootIconName, size: 16)?.draw(
                    in: CGRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14),
                    from: .zero, operation: .sourceOver, fraction: isActive ? (hover == i ? 1 : 0.7) : 0.4,
                    respectFlipped: true, hints: nil)
            case .arrow:
                Icons.shared.image("go-next", size: 16)?.draw(
                    in: CGRect(x: r.midX - 6, y: r.midY - 6, width: 12, height: 12),
                    from: .zero, operation: .sourceOver, fraction: isActive ? (hover == i ? 1 : 0.55) : 0.35,
                    respectFlipped: true, hints: nil)
            case .more:
                ("…" as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.midY - 9), withAttributes: [.font: crumbFont, .foregroundColor: textColor])
            case .crumb(_, let title, let last):
                let missing = last && missingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: last ? crumbBoldFont : crumbFont,
                    .foregroundColor: missing ? Theme.windowTextInactive.withAlphaComponent(0.6) : textColor,
                ]
                let ts = (title as NSString).size(withAttributes: attrs)
                (title as NSString).draw(at: CGPoint(x: r.minX + 5, y: r.midY - ts.height / 2), withAttributes: attrs)
                if missing {
                    Theme.windowTextInactive.withAlphaComponent(0.6).setStroke()
                    let underline = NSBezierPath(); underline.move(to: CGPoint(x: r.minX + 5, y: r.midY + ts.height / 2))
                    underline.line(to: CGPoint(x: r.minX + 5 + ts.width, y: r.midY + ts.height / 2)); underline.lineWidth = 1
                    underline.setLineDash([2, 2], count: 2, phase: 0); underline.stroke()
                }
            }
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

    private func segmentIndex(at p: CGPoint) -> Int? { segments.firstIndex { $0.rect.contains(p) } }

    /// Where the crumb of `u` is drawn (nil: not shown).
    func crumbRect(_ u: URL) -> CGRect? {
        rebuildIfNeeded()
        return segments.first { if case .crumb(let c, _, _) = $0.kind { c.path == u.path } else { false } }?.rect
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isEditing else { return }
        let i = segmentIndex(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
        if let i, case .crumb(let u, _, _) = segments[i].kind {
            toolTip = LocationNaming.address(for: u)
        } else if i == nil {
            toolTip = "Click to Edit Location"
        } else {
            toolTip = nil
        }
    }

    private var fieldHover = false
    override func mouseEntered(with event: NSEvent) { fieldHover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; fieldHover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        delegate?.breadcrumbActivated(self)
        guard !isEditing else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = segmentIndex(at: p) else {
            // Empty area: dragging moves the window (it sits in the title bar); a click edits the location.
            let start = event.locationInWindow
            while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if e.type == .leftMouseUp { beginEditing(selectAll: false); return }
                if hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 3 {
                    window?.performDrag(with: event)
                    return
                }
            }
            return
        }
        pressed = i
        needsDisplay = true
        // Read once: a menu item chosen during popUp navigates, which rebuilds (and can shrink) `segments`.
        let (kind, rect) = (segments[i].kind, segments[i].rect)
        switch kind {
        case .placesButton: showPlacesMenu(at: rect)
        case .rootArrow: showRootMenu(at: rect)
        case .arrow(let u): showSubfolderMenu(of: u, at: rect)
        case .more(let urls): showMenu(urls.map { ($0, $0.folderName) }, at: rect)
        case .crumb: return
        }
        pressed = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = pressed else { return }
        pressed = nil
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        guard i < segments.count, segments[i].rect.contains(p), case .crumb(let u, _, _) = segments[i].kind else { return }
        // A virtual location's only crumb is where the view already is.
        if LocationKind.of(url).isVirtual && u == url && !event.modifierFlags.contains(.command) { return }
        let mods = event.modifierFlags
        delegate?.breadcrumb(self, navigateTo: u, newTab: mods.contains(.command))
    }

    /// Middle click opens a crumb in a new tab; other buttons (mouse back/forward) go up the responder chain.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if let i = segmentIndex(at: p), case .crumb(let u, _, _) = segments[i].kind {
            delegate?.breadcrumb(self, navigateTo: u, newTab: true)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Mouse wheel over a crumb switches to sibling folders (KUrlNavigator).
        let p = convert(event.locationInWindow, from: nil)
        // Local folders only: listing a remote one would block the window on every wheel tick.
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0, !LocationKind.of(url).isVirtual, let i = segmentIndex(at: p),
            case .crumb(let u, _, _) = segments[i].kind, u.isFileURL, u.path != "/", u.path != ""
        else { super.scrollWheel(with: event); return }
        let parent = u.deletingLastPathComponent()
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        // The next ticks of one turn of the wheel use the list the first one read.
        if let c = siblings, c.parent == parent, Date().timeIntervalSince(c.time) < 2 { return go(from: u, in: c.folders, by: step) }
        // Listed off the main thread: a big folder or a disk on the network (under /Volumes, a file URL too) never
        // stalls the window; the step applies if the crumb still shows that folder by then.
        siblingRequest += 1
        let request = siblingRequest
        let list = Self.listFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders = list(parent)
            DispatchQueue.main.async {
                guard let self, self.siblingRequest == request else { return }
                self.siblings = (parent, folders, Date())
                guard self.window != nil, self.url.path == u.path || self.url.path.hasPrefix(u.path + "/") else { return }
                self.go(from: u, in: folders, by: step)
            }
        }
    }

    private func go(from u: URL, in folders: [URL], by step: Int) {
        guard let i = folders.firstIndex(where: { $0.path == u.path }), folders.indices.contains(i + step) else { return }
        delegate?.breadcrumb(self, navigateTo: folders[i + step], newTab: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        var target = url
        if let i = segmentIndex(at: p), case .crumb(let u, _, _) = segments[i].kind { target = u }
        m.addItem(withTitle: "Copy Location", action: #selector(copyLocation(_:)), keyEquivalent: "").representedObject = target
        m.addItem(withTitle: "Paste Location", action: #selector(pasteLocation), keyEquivalent: "")
        m.addItem(.separator())
        let nt = m.addItem(
            withTitle: "Open “\(target.folderName.isEmpty ? "/" : target.folderName)” in New Tab", action: #selector(openInNewTab(_:)),
            keyEquivalent: "")
        nt.representedObject = target
        m.addItem(.separator())
        let edit = m.addItem(withTitle: "Edit", action: #selector(setEditable(_:)), keyEquivalent: "")
        edit.state = Settings.shared.editableLocation ? .on : .off
        edit.tag = 1
        let nav = m.addItem(withTitle: "Navigate", action: #selector(setEditable(_:)), keyEquivalent: "")
        nav.state = Settings.shared.editableLocation ? .off : .on
        nav.tag = 0
        m.addItem(.separator())
        let full = m.addItem(withTitle: "Show Full Path", action: #selector(toggleFullPath), keyEquivalent: "")
        full.state = Settings.shared.showFullPathInLocation ? .on : .off
        for it in m.items { it.target = self }
        return m
    }

    @objc private func copyLocation(_ s: NSMenuItem) {
        NSPasteboard.general.clearContents()
        let u = (s.representedObject as? URL) ?? url
        NSPasteboard.general.setString(LocationNaming.address(for: u), forType: .string)
    }

    /// Goes to the location on the clipboard (a path, "~/…", or a remote URL), like typing it.
    @objc private func pasteLocation() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
            !s.contains("\n")
        else { return }
        delegate?.breadcrumb(self, navigateTo: typedURL(s), newTab: false)
    }

    @objc private func openInNewTab(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.breadcrumb(self, navigateTo: u, newTab: true) }
    }

    /// "Edit" (tag 1) or "Navigate" (tag 0); choosing the current mode again keeps it.
    @objc private func setEditable(_ s: NSMenuItem) {
        let editable = s.tag == 1
        if Settings.shared.editableLocation != editable { Settings.shared.editableLocation = editable }
        if editable { beginEditing(selectAll: false) } else { endEditing() }
    }

    @objc private func toggleFullPath() {
        Settings.shared.showFullPathInLocation.toggle()
        rebuild()
    }

    // MARK: Menus

    private var subfolderRequest = 0
    /// The wheel's sibling folders, by parent, and when they were read.
    private var siblings: (parent: URL, folders: [URL], time: Date)?
    private var siblingRequest = 0
    /// Lists a folder's subfolders (tests watch where it runs).
    nonisolated(unsafe) static var listFolders: (URL) -> [URL] = { BreadcrumbView.subfolders(of: $0) }

    private nonisolated static func subfolders(of u: URL) -> [URL] {
        if let p = RemoteFS.provider(for: u) {
            return ((try? p.list(u)) ?? []).filter { $0.isDirectory && !$0.isHidden }.map(\.url)
                .sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap {
            let c = u.appendingPathComponent($0)
            var d: ObjCBool = false
            guard FileManager.default.fileExists(atPath: c.path, isDirectory: &d), d.boolValue else { return nil }
            if (try? c.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return nil }
            return c
        }
    }

    private func showSubfolderMenu(of u: URL, at r: CGRect) {
        let next = url.path.hasPrefix(u.path == "/" ? "/" : u.path + "/") ? url.pathComponents.dropFirst(u.pathComponents.count).first : nil
        // Listed off the main thread, local folders too (a big folder, a disk on the network under /Volumes); the menu
        // opens when the list is there, unless another one was asked for meanwhile.
        subfolderRequest += 1
        let request = subfolderRequest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let folders = Self.subfolders(of: u)
            DispatchQueue.main.async {
                guard let self, self.window != nil, self.subfolderRequest == request else { return }
                self.showMenu(folders.map { ($0, $0.folderName) }, at: r, bold: next)
            }
        }
    }

    /// The root segment's glyph: the home folder for paths under it, the disk for other local paths, a server for
    /// remote ones.
    var rootIconName: String {
        guard url.isFileURL else { return "network-server" }
        let p = url.standardizedFileURL.path, home = NSHomeDirectory()
        return p == home || p.hasPrefix(home + "/") ? "user-home" : "drive-harddisk"
    }

    private func showRootMenu(at r: CGRect) {
        // "Go to any location on the path": every ancestor of the first crumb + places.
        guard url.isFileURL else {
            // Remote: the server's root and each folder down to here (virtual locations: just themselves).
            showMenu(remoteCrumbs().map { ($0.url, $0.title) }, at: r)
            return
        }
        var entries: [(URL, String)] = []
        var u = url.standardizedFileURL
        while u.path != "/" && !u.path.isEmpty { entries.append((u, u.lastPathComponent)); u = u.deletingLastPathComponent() }
        entries.append((URL(fileURLWithPath: "/"), volumeName(for: URL(fileURLWithPath: "/"))))
        showMenu(entries.reversed(), at: r)
    }

    /// Every shown place (Places panel hidden), local and remote.
    private func showPlacesMenu(at r: CGRect) {
        let shown = places.filter { !$0.hidden }
        showMenu(shown.map { ($0.url, $0.title) }, at: r, icons: shown.map(\.icon))
    }

    private func showMenu(_ entries: [(URL, String)], at r: CGRect, bold: String? = nil, icons: [String]? = nil) {
        let m = NSMenu()
        m.autoenablesItems = false
        for (i, e) in entries.prefix(Self.maxMenuEntries).enumerated() {
            let it = NSMenuItem(title: e.1, action: #selector(menuNavigate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.0
            it.image = Icons.shared.image(icons?[safe: i] ?? IconTheme.folderIconName(e.0), size: 16)
            if e.1 == bold { it.attributedTitle = NSAttributedString(string: e.1, attributes: [.font: NSFont.menuFont(ofSize: 0).bold]) }
            m.addItem(it)
        }
        if entries.isEmpty { m.addItem(withTitle: "No subfolders", action: nil, keyEquivalent: "").isEnabled = false }
        m.popUp(positioning: nil, at: CGPoint(x: r.minX, y: r.maxY + 4), in: self)
        hover = nil
        needsDisplay = true
    }

    @objc private func menuNavigate(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL {
            delegate?.breadcrumb(self, navigateTo: u, newTab: NSEvent.modifierFlags.contains(.command))
        }
    }

    // MARK: Edit mode

    private var fieldFrame: CGRect { bounds.insetBy(dx: 16, dy: 7).offsetBy(dx: 2, dy: 0) }

    func beginEditing(selectAll: Bool) {
        if !isEditing {
            isEditing = true
            completion = CompletionSource()
            let f = PathField(frame: fieldFrame)
            f.stringValue = editText
            f.font = Theme.font
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.textColor = Theme.windowText
            f.delegate = self
            f.cell?.isScrollable = true
            f.cell?.wraps = false
            addSubview(f)
            field = f
            needsDisplay = true
        }
        window?.makeFirstResponder(field)
        if let ed = field?.currentEditor() {
            ed.selectedRange =
                selectAll
                ? NSRange(location: 0, length: field!.stringValue.utf16.count)
                : NSRange(location: field!.stringValue.utf16.count, length: 0)
        }
    }

    /// The location as text in the field (folders end with "/" so typing continues inside them).
    private var editText: String { !url.isFileURL ? url.absoluteString : (url.path == "/" ? "/" : url.path + "/") }

    /// "Make location bar editable": the field is there from the start (without taking the keyboard focus).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, Settings.shared.editableLocation, !isEditing else { return }
        let responder = window?.firstResponder
        beginEditing(selectAll: false)
        if let responder, responder !== window?.firstResponder { window?.makeFirstResponder(responder) }
    }

    func endEditing() {
        guard isEditing, !Settings.shared.editableLocation else { return }
        isEditing = false
        completion = CompletionSource()
        field?.removeFromSuperview()
        field = nil
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let u = typedURL(field?.stringValue.trimmingCharacters(in: .whitespaces) ?? "")
            endEditing()
            delegate?.breadcrumb(self, navigateTo: u, newTab: false)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            // Editable location bar: Escape drops what was typed.
            field?.stringValue = editText
            endEditing()
            delegate?.breadcrumbActivated(self)
            return true
        }
        if sel == #selector(NSResponder.insertTab(_:)) {
            complete(textView, unique: false)
            return true
        }
        return false
    }

    /// The location typed in the field: file URL, remote (sftp://, smb://, user@host:path…), or a path.
    /// Relative paths are relative to the shown folder, as in KUrlNavigator.
    private func typedURL(_ raw: String) -> URL {
        if raw.hasPrefix("file://"), let u = URL(string: raw) { return u }
        if let remote = RemoteFS.parseTyped(raw) { return remote }
        let path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), url.isFileURL { return url.appendingPathComponent(path).standardizedFileURL }
        return URL(fileURLWithPath: path)
    }

    private var isCompleting = false
    private static let backspaceKey: UInt16 = 51
    private static let forwardDeleteKey: UInt16 = 117

    func controlTextDidChange(_ obj: Notification) {
        guard !isCompleting, let tv = field?.currentEditor() as? NSTextView else { return }
        // Inline auto-completion of a unique folder match (KDE's "popup auto" completion), never while deleting.
        if let ev = NSApp.currentEvent, ev.type == .keyDown, ev.keyCode == Self.backspaceKey || ev.keyCode == Self.forwardDeleteKey { return }
        complete(tv, unique: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !Settings.shared.editableLocation { endEditing() }
    }

    /// Completes the last path component with a matching folder. `unique` (while typing): only a single match,
    /// with the added part selected so the next keystroke replaces it. Otherwise (Tab): the first match, or accept
    /// the pending inline completion. Only the last component is replaced, so typed characters are never lost.
    private func complete(_ tv: NSTextView, unique: Bool) {
        let typed = tv.string as NSString
        let typedLen = typed.length
        let sel = tv.selectedRange()
        if !unique, sel.length > 0, NSMaxRange(sel) == typedLen {
            tv.setSelectedRange(NSRange(location: typedLen, length: 0))
            return
        }
        guard sel.location == typedLen else { return }
        let slash = typed.range(of: "/", options: .backwards)
        // No slash: a name relative to the shown folder (as `typedURL` reads it).
        guard slash.location != NSNotFound || (url.isFileURL && !typed.hasPrefix("~")) else { return }
        let prefixLen = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
        let partial = typed.substring(from: prefixLen)
        guard !partial.isEmpty else { return }
        var dir = (typed.substring(to: prefixLen) as NSString).expandingTildeInPath
        if !dir.hasPrefix("/") {
            guard url.isFileURL, !typed.contains("://") else { return }
            dir = url.appendingPathComponent(dir).path
        }
        let matches = completion.folders(in: dir, matching: partial)
        guard let first = matches.first, !unique || matches.count == 1 else { return }
        let newLen = prefixLen + (first as NSString).length
        guard newLen > typedLen || !unique else { return }
        // Replace through the text system so the field editor stays consistent.
        let range = NSRange(location: prefixLen, length: typedLen - prefixLen)
        isCompleting = true
        if tv.shouldChangeText(in: range, replacementString: first) {
            tv.replaceCharacters(in: range, with: first)
            tv.didChangeText()
        }
        isCompleting = false
        tv.setSelectedRange(
            unique
                ? NSRange(location: min(typedLen, newLen), length: max(0, newLen - typedLen))
                : NSRange(location: newLen, length: 0))
    }

    // MARK: Drops onto crumbs

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let i = segmentIndex(at: p)
        if i != dropHover {
            dropHover = i
            needsDisplay = true
        }
        let arrow: URL? = i.flatMap { if case .arrow(let u) = segments[$0].kind { return u } else { return nil } }
        arrowSpringLoader.hover(arrow == nil ? nil : i) { [weak self] in
            guard let self, let i, let u = arrow, self.dropHover == i, let r = self.segments[safe: i]?.rect else { return }
            self.showSubfolderMenu(of: u, at: r)
        }
        guard let u = crumbFolder(i), DropTargetPolicy.accepts(DropTargetPolicy.urls(sender), into: u) else { return [] }
        return DropTargetPolicy.operation(for: sender)
    }

    /// The folder of the crumb at segment `i` (not an arrow, nor the editable field).
    private func crumbFolder(_ i: Int?) -> URL? {
        guard let i, case .crumb(let u, _, _) = segments[safe: i]?.kind else { return nil }
        return u
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDropHover() }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DropTargetPolicy.dragEnded()
        endDropHover()
    }

    private func endDropHover() {
        dropHover = nil
        arrowSpringLoader.cancel()
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        endDropHover()
        let urls = DropTargetPolicy.urls(sender)
        guard let u = crumbFolder(segmentIndex(at: p)), DropTargetPolicy.accepts(urls, into: u) else { return false }
        delegate?.breadcrumb(self, drop: urls, onto: u, operation: DropTargetPolicy.operation(for: sender))
        return true
    }
}

/// Path text field that keeps focus styling in sync with the breadcrumb frame.
final class PathField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        superview?.needsDisplay = true
        return super.becomeFirstResponder()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
