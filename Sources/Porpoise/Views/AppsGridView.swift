import AppKit
import PorpoiseCore
import PorpoiseServices

/// The icons. Draws itself; selection is the model's, so menu commands act on the selected apps.
final class AppsGridView: NSView, NSDraggingSource {
    weak var owner: AppsView?
    let model: DirectoryModel

    private static let cell = CGSize(width: 136, height: 136)
    private static let iconSize: CGFloat = 80
    private static let sideMargin: CGFloat = 36
    private var columns = 1
    private var originX: CGFloat = 0
    private var hover: Int?
    private var mouseDownPoint: CGPoint?
    private var mouseDownIndex: Int?
    private var running: Set<String> = []
    private var icons: [URL: NSImage] = [:]
    private var names: [URL: String] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Where each shown app's cell is, after the last layout (an animation moves the drawing toward these).
    private var targets: [URL: CGRect] = [:]
    private var shownItems: [URL: FileItem] = [:]
    /// A running filter animation: apps glide to their new places, leaving ones shrink and fade, new ones grow in.
    private struct Transition {
        let start: CFTimeInterval
        let from: [URL: CGRect]
        let leaving: [(item: FileItem, cell: CGRect)]
    }
    private var transition: Transition?
    private var link: CADisplayLink?
    private static let duration: CFTimeInterval = 0.34

    init(model: DirectoryModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshRunning() })
        }
        refreshRunning()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        link?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let o = owner { o.host?.appsViewDidBecomeActive(o) }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    /// Out of the window (tab closed mid-animation): the display link would keep the grid alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        link?.invalidate()
        link = nil
        transition = nil
    }

    private func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        needsDisplay = true
    }

    // MARK: Layout

    func updateLayout(width: CGFloat, animated: Bool = false) {
        // Where things are drawn now, before the layout changes: the start of a new animation.
        let before = animated ? currentCells() : [:]
        let beforeItems = shownItems
        columns = max(1, Int((width - 2 * Self.sideMargin) / Self.cell.width))
        let used = CGFloat(min(columns, max(model.rows.count, 1))) * Self.cell.width
        originX = max(Self.sideMargin, (width - CGFloat(columns) * Self.cell.width) / 2)
        if model.rows.count < columns { originX = (width - used) / 2 }
        let rowCount = (model.rows.count + columns - 1) / columns
        let h = CGFloat(rowCount) * Self.cell.height + 16
        let visibleHeight = (enclosingScrollView?.contentSize.height ?? 0) - (enclosingScrollView?.contentInsets.top ?? 0)
        setFrameSize(NSSize(width: width, height: max(h, visibleHeight)))
        updateTrackingAreas()
        targets = Dictionary(model.rows.enumerated().map { ($1.item.url, cellRect($0)) }, uniquingKeysWith: { a, _ in a })
        shownItems = Dictionary(model.rows.map { ($0.item.url, $0.item) }, uniquingKeysWith: { a, _ in a })
        guard animated, !before.isEmpty, window != nil else { return }
        // Reduce Motion: no gliding, the apps only fade.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let leaving = before.compactMap { url, cell in targets[url] == nil ? beforeItems[url].map { (item: $0, cell: cell) } : nil }
        let from = still ? targets.filter { before[$0.key] != nil } : before.filter { targets[$0.key] != nil }
        transition = Transition(start: CACurrentMediaTime(), from: from, leaving: leaving)
        lastTransitionInfo = "moving=\(from.filter { $0.value != targets[$0.key] }.count) staying=\(from.count) leaving=\(leaving.count) appearing=\(targets.count - from.count)"
        // Room for the apps on their way out; the grid takes its real height when the animation ends.
        if let low = (before.values.map(\.maxY) + [frame.height]).max(), low > frame.height { setFrameSize(NSSize(width: width, height: low)) }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }
        needsDisplay = true
    }

    /// For tests: an animation is running, with how many apps gliding and how many leaving.
    var animationInfo: String { lastTransitionInfo }
    private var lastTransitionInfo = "none"

    /// 0…1 through the running animation, eased out (fast start, gentle landing).
    private var progress: CGFloat {
        guard let t = transition else { return 1 }
        let x = min(1, max(0, (CACurrentMediaTime() - t.start) / Self.duration))
        return CGFloat(1 - pow(1 - x, 3))
    }

    @objc private func step() {
        needsDisplay = true
        if progress >= 1 {
            transition = nil
            link?.invalidate()
            link = nil
            updateLayout(width: bounds.width)
        }
    }

    /// Each shown app's cell as drawn at this moment.
    private func currentCells() -> [URL: CGRect] {
        guard transition != nil else { return targets }
        var out: [URL: CGRect] = [:]
        for (url, target) in targets { out[url] = placement(url, target: target).cell }
        return out
    }

    /// Where and how an app is drawn now: gliding from its old place, or growing in if it just appeared.
    private func placement(_ url: URL, target: CGRect) -> (cell: CGRect, alpha: CGFloat, scale: CGFloat) {
        guard let t = transition else { return (target, 1, 1) }
        let p = progress
        guard let from = t.from[url] else { return (target, p, 0.82 + 0.18 * p) }
        let cell = CGRect(x: from.minX + (target.minX - from.minX) * p, y: from.minY + (target.minY - from.minY) * p,
                          width: target.width, height: target.height)
        return (cell, 1, 1)
    }

    private func cellRect(_ i: Int) -> CGRect {
        CGRect(x: originX + CGFloat(i % columns) * Self.cell.width, y: CGFloat(i / columns) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    private func iconRect(_ i: Int) -> CGRect { iconRect(in: cellRect(i)) }

    private func iconRect(in c: CGRect) -> CGRect {
        CGRect(x: c.midX - Self.iconSize / 2, y: c.minY + 10, width: Self.iconSize, height: Self.iconSize)
    }

    private func index(at p: CGPoint) -> Int? {
        guard p.x >= originX, p.y >= 0 else { return nil }
        let col = Int((p.x - originX) / Self.cell.width), row = Int(p.y / Self.cell.height)
        guard col < columns else { return nil }
        let i = row * columns + col
        guard i < model.rows.count else { return nil }
        // The icon and its name, not the empty corners of the cell.
        return cellRect(i).insetBy(dx: 10, dy: 2).contains(p) ? i : nil
    }

    func scrollToCurrent() {
        guard let c = model.currentURL, let i = model.index(of: c) else { return }
        scrollToVisible(cellRect(i).insetBy(dx: 0, dy: -12))
    }

    // MARK: Drawing

    private func icon(for item: FileItem) -> NSImage {
        if let i = icons[item.url] { return i }
        let i = NSWorkspace.shared.icon(forFile: item.url.path)
        i.size = NSSize(width: 256, height: 256)
        icons[item.url] = i
        return i
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let p = progress
        // Apps leaving the result shrink and fade out quickly, under the ones that stay.
        for l in transition?.leaving ?? [] {
            drawItem(l.item, cell: l.cell, selected: false, hovered: false, focused: focused,
                     alpha: max(0, 1 - p * 1.6), scale: 1 - 0.18 * p, dirty: dirtyRect)
        }
        for (i, row) in model.rows.enumerated() {
            let item = row.item
            let place = placement(item.url, target: cellRect(i))
            drawItem(item, cell: place.cell, selected: model.selection.contains(item.url), hovered: hover == i,
                     focused: focused, alpha: place.alpha, scale: place.scale, dirty: dirtyRect)
        }
    }

    /// One app: highlight, icon, name and running dot, all in theme colours (like the other views).
    private func drawItem(_ item: FileItem, cell: CGRect, selected: Bool, hovered: Bool, focused: Bool,
                          alpha: CGFloat, scale: CGFloat, dirty: CGRect) {
        guard alpha > 0.01, cell.intersects(dirty), let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        ctx.setAlpha(alpha)
        if scale != 1 {
            ctx.translateBy(x: cell.midX, y: cell.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -cell.midX, y: -cell.midY)
        }
        let ir = iconRect(in: cell)
        if selected || hovered {
            let bg = NSBezierPath(roundedRect: ir.insetBy(dx: -9, dy: -9), xRadius: 18, yRadius: 18)
            let fill = selected ? (hovered ? Theme.itemSelectedHoverFill : Theme.itemSelectedFill) : Theme.itemHoverFill
            (selected && !focused ? fill.withAlphaComponent(fill.alphaComponent * 0.6) : fill).setFill()
            bg.fill()
            if selected {
                Theme.itemSelectedOutline.setStroke()
                bg.lineWidth = 1
                bg.stroke()
            }
        }
        // A soft shadow under the icon, like the Dock.
        NSGraphicsContext.saveGraphicsState()
        let iconShadow = NSShadow()
        iconShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        iconShadow.shadowBlurRadius = 7
        iconShadow.shadowOffset = NSSize(width: 0, height: -3)
        iconShadow.set()
        icon(for: item).draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        // The name, on the selection colour when selected.
        let name = names[item.url] ?? { let n = AppLibrary.displayName(item.url); names[item.url] = n; return n }()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.nameFont, .paragraphStyle: Self.namePara,
            .foregroundColor: selected && focused ? Theme.selectionText : Theme.viewText,
        ]
        let maxW = cell.width - 14
        let textW = min(maxW, ceil((name as NSString).size(withAttributes: [.font: Self.nameFont]).width))
        let textRect = CGRect(x: cell.midX - maxW / 2, y: ir.maxY + 12, width: maxW, height: 17)
        if selected {
            let capsule = CGRect(x: cell.midX - textW / 2 - 7, y: textRect.minY - 1, width: textW + 14, height: 19)
            (focused ? Theme.selection : Theme.itemSelectedFill).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 9.5, yRadius: 9.5).fill()
        }
        (name as NSString).draw(in: textRect, withAttributes: attrs)

        // Running apps get the Dock's dot.
        if running.contains(item.url.standardizedFileURL.path) {
            Theme.viewTextInactive.setFill()
            NSBezierPath(ovalIn: CGRect(x: cell.midX - 2, y: textRect.maxY + 5, width: 4, height: 4)).fill()
        }
    }

    private static let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let namePara: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { setHover(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ i: Int?) {
        guard i != hover else { return }
        if let h = hover, h < model.rows.count { setNeedsDisplay(cellRect(h)) }
        hover = i
        if let i { setNeedsDisplay(cellRect(i)) }
        if let o = owner { o.host?.appsView(o, hovered: i.map { model.rows[$0].item }) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        mouseDownPoint = p
        mouseDownIndex = i
        guard let i else {
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) { model.selection = [] }
            return
        }
        let url = model.rows[i].item.url
        if event.modifierFlags.contains(.command) {
            if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
        } else if event.modifierFlags.contains(.shift), let anchor = model.currentURL, let a = model.index(of: anchor) {
            model.selection = Set(model.rows[min(a, i)...max(a, i)].map(\.item.url))
        } else if !model.selection.contains(url) {
            model.selection = [url]
        }
        model.currentURL = url
        needsDisplay = true
        if event.clickCount == 2, let o = owner { o.host?.appsView(o, open: model.selectedItems) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, mouseDownIndex != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        beginDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click on one of several selected apps selects just that one.
        // The index is from mouseDown: an app installed or removed meanwhile can have changed the rows.
        if mouseDownPoint != nil, let i = mouseDownIndex, i < model.rows.count,
           event.modifierFlags.intersection([.command, .shift]).isEmpty, event.clickCount == 1 {
            model.selection = [model.rows[i].item.url]
            needsDisplay = true
        }
        mouseDownPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if let i {
            let url = model.rows[i].item.url
            if !model.selection.contains(url) { model.selection = [url] }
            model.currentURL = url
        } else {
            model.selection = []
        }
        needsDisplay = true
        guard let o = owner else { return nil }
        return o.host?.appsView(o, menuFor: i.map { model.rows[$0].item })
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case 123: move(by: -1, extend: event.modifierFlags.contains(.shift)); return            // ←
        case 124: move(by: 1, extend: event.modifierFlags.contains(.shift)); return             // →
        case 126:                                                                               // ↑
            if mods.contains(.command) { break }
            move(by: -columns, extend: event.modifierFlags.contains(.shift)); return
        case 125:                                                                               // ↓, ⌘↓ opens
            if mods.contains(.command) { openSelection(); return }
            move(by: columns, extend: event.modifierFlags.contains(.shift)); return
        case 36, 76: openSelection(); return                                                    // Return
        case 49: if let o = owner { o.host?.appsViewQuickLook(o) }; return                      // Space
        case 53: model.selection = []; needsDisplay = true; return                              // Escape
        default: break
        }
        // Letters search, as in Launchpad.
        if mods.isEmpty, let chars = event.characters, let c = chars.unicodeScalars.first,
           CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains(c) {
            owner?.startSearch(with: chars)
            return
        }
        super.keyDown(with: event)
    }

    private func openSelection() {
        let items = model.selectedItems
        if !items.isEmpty, let o = owner { o.host?.appsView(o, open: items) }
    }

    private func move(by delta: Int, extend: Bool) {
        guard !model.rows.isEmpty else { return }
        let cur = model.currentURL.flatMap { model.index(of: $0) }
        let next = cur.map { min(max($0 + delta, 0), model.rows.count - 1) } ?? 0
        let url = model.rows[next].item.url
        if extend { model.selection.insert(url) } else { model.selection = [url] }
        model.currentURL = url
        scrollToVisible(cellRect(next).insetBy(dx: 0, dy: -12))
        needsDisplay = true
    }

    // MARK: Drag source (onto the Dock to keep, onto its Trash to delete, into folders or other apps)

    private func beginDrag(_ event: NSEvent) {
        let items = model.rows.enumerated().filter { model.selection.contains($0.element.item.url) }
        let urls = items.map(\.element.item.url)
        let dragItems = items.enumerated().map { n, pair -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: FileDragWriter(url: pair.element.item.url, allURLs: n == 0 ? urls : nil))
            di.setDraggingFrame(iconRect(pair.offset), contents: icon(for: pair.element.item))
            return di
        }
        guard !dragItems.isEmpty else { return }
        let s = beginDraggingSession(with: dragItems, event: event, source: self)
        s.animatesToStartingPositionsOnCancelOrFail = true
        s.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation == .delete else { return }
        let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { FileOperationsController.shared.trash(urls, window: window, sound: .dragToTrash) }
    }

    // MARK: Drop target (install: drop an app from a disk image or Downloads)

    private func droppedApps(_ sender: NSDraggingInfo) -> [URL] {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { $0.pathExtension == "app" && $0.deletingLastPathComponent().standardizedFileURL != AppLibrary.location }
    }

    private func installOperation(_ sender: NSDraggingInfo, _ apps: [URL]) -> NSDragOperation {
        guard !apps.isEmpty else { return [] }
        // Finder's rule: same volume moves, another volume (a disk image) copies; Option always copies.
        let vol = { (u: URL) in try? u.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        let sameVolume = apps.allSatisfy { vol($0) == vol(AppLibrary.location) }
        return NSEvent.modifierFlags.contains(.option) || !sameVolume ? .copy : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { installOperation(sender, droppedApps(sender)) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { installOperation(sender, droppedApps(sender)) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let apps = droppedApps(sender)
        let op = installOperation(sender, apps)
        guard !apps.isEmpty else { return false }
        FileOperationsController.shared.run(op == .move ? .move : .copy, apps, to: AppLibrary.location, window: window)
        return true
    }
}
