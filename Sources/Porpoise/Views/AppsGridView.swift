import AppKit
import PorpoiseCore
import PorpoiseServices

/// The icons. Draws itself; selection is the model's, so menu commands act on the selected apps.
final class AppsGridView: NSView, NSDraggingSource {
    weak var owner: AppsView?
    let model: DirectoryModel

    static let defaultIconSize: CGFloat = 80
    private static let sideMargin: CGFloat = 36
    /// Icon size; `liveIconSize` overrides it during pinch / slider / animated zoom (saved when done), as in Icons.
    var iconSize: CGFloat { liveIconSize ?? savedIconSize }
    private(set) var liveIconSize: CGFloat?
    private var savedIconSize = CGFloat(Settings.shared.appLibraryIconSize)
    private var zoomCommitTimer: Timer?
    private let zoomAnimator = Animator()
    var onZoomPreview: ((CGFloat) -> Void)?

    private var columns = 1
    private var originX: CGFloat = 0
    private var hover: Int?
    private var mouseDownPoint: CGPoint?
    private var mouseDownIndex: Int?
    private var running: Set<String> = []
    private var icons: [URL: NSImage] = [:]
    /// Each app's icon as drawn (its shadow included), rendered once per size for the screen's scale and colours:
    /// drawing the icon file itself on every frame of a resize or zoom resampled and colour-matched its 1024 px picture
    /// each time. Keyed by the size rendered (see `renderSize`).
    private var tiles: [CGFloat: [URL: NSImage]] = [:] { didSet { if tiles.isEmpty { tileSizes = [] } } }
    /// The sizes in `tiles`, oldest first: a few are kept, to stand in while a new size renders.
    private var tileSizes: [CGFloat] = []
    /// Until when the frame being drawn may render tiles. A zoom step needs every visible tile again (about 1.5 ms
    /// each, mostly the icon file's picture at the new size): they come over a few frames, the nearest size already
    /// rendered standing in, scaled, so no frame is held up.
    private var renderDeadline: CFTimeInterval = .infinity
    /// Some tile was drawn from a stand-in: the next frame renders more.
    private var tilesPending = false
    private var names: [URL: (text: String, width: CGFloat)] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Where each shown app's cell is, after the last layout (an animation moves the drawing toward these).
    private var targets: [URL: CGRect] = [:]
    private var shownItems: [URL: FileItem] = [:]
    /// A running filter animation: apps glide to their new places, leaving ones shrink and fade, new ones grow in.
    private struct Transition {
        var from: [URL: CGRect]
        var leaving: [(item: FileItem, cell: CGRect)]
    }
    private var transition: Transition?
    /// Steps the animation with the display (its clock starts at the first frame shown, and it keeps going during a
    /// live resize).
    private let animator = Animator()
    /// 0…1 through the running animation, eased out (fast start, gentle landing).
    private var progress: CGFloat = 1
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

    /// Another screen (another scale or colour space): the icons are rendered again for it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tiles = [:]
    }

    /// Out of the window (tab closed mid-animation): the animation stops, a zoom is saved.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tiles = [:]
        guard window == nil else { return }
        commitZoom()
        zoomAnimator.stop()
        animator.stop()
        transition = nil
    }

    /// Left the library (another folder shown) mid-zoom: the size reached is kept.
    override func viewDidHide() {
        super.viewDidHide()
        zoomAnimator.stop()
        commitZoom()
    }

    private func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        needsDisplay = true
    }

    // MARK: Layout

    /// The grid got another width (window or split pane resized): when the apps reflow into another number of
    /// columns they glide to their new places, otherwise the layout just follows.
    func resize(width: CGFloat) {
        updateLayout(width: width, animated: columns(for: width) != columns && !targets.isEmpty)
    }

    private func columns(for width: CGFloat) -> Int { max(1, Int((width - 2 * Self.sideMargin) / cell.width)) }

    func updateLayout(width: CGFloat, animated: Bool = false) {
        // Where things are drawn now, before the layout changes: the start of a new animation.
        let before = animated ? currentCells() : [:]
        let beforeItems = shownItems
        let cell = cell
        columns = columns(for: width)
        let used = CGFloat(min(columns, max(model.rows.count, 1))) * cell.width
        originX = max(Self.sideMargin, (width - CGFloat(columns) * cell.width) / 2)
        if model.rows.count < columns { originX = (width - used) / 2 }
        let rowCount = (model.rows.count + columns - 1) / columns
        let h = CGFloat(rowCount) * cell.height + 16
        let visibleHeight = (enclosingScrollView?.contentSize.height ?? 0) - (enclosingScrollView?.contentInsets.top ?? 0)
        setFrameSize(NSSize(width: width, height: max(h, visibleHeight)))
        updateTrackingAreas()
        targets = Dictionary(model.rows.enumerated().map { ($1.item.url, cellRect($0)) }, uniquingKeysWith: { a, _ in a })
        shownItems = Dictionary(model.rows.map { ($0.item.url, $0.item) }, uniquingKeysWith: { a, _ in a })
        guard animated, !before.isEmpty, window != nil else { return }
        glide(from: before, items: beforeItems, duration: Self.duration)
    }

    /// Starts the apps gliding from `before` (where they were drawn) to their cells; the ones no longer shown shrink
    /// and fade out (`items` has them), new ones grow in.
    private func glide(from before: [URL: CGRect], items beforeItems: [URL: FileItem], duration: CFTimeInterval) {
        // Reduce Motion: no gliding, the apps only fade.
        let still = Animator.reducesMotion()
        let leaving = before.compactMap { url, cell in targets[url] == nil ? beforeItems[url].map { (item: $0, cell: cell) } : nil }
        let from = still ? targets.filter { before[$0.key] != nil } : before.filter { targets[$0.key] != nil }
        transition = Transition(from: from, leaving: leaving)
        lastTransitionInfo =
            "moving=\(from.filter { $0.value != targets[$0.key] }.count) staying=\(from.count) leaving=\(leaving.count) appearing=\(targets.count - from.count)"
        // Room for the apps on their way out; the grid takes its real height when the animation ends. Not on a zoom
        // (no app leaves): the scroll position would jump when the grid shrinks back.
        let width = frame.width
        let old = beforeItems.isEmpty ? [] : before.values.map(\.maxY)
        if let low = (old + [frame.height]).max(), low > frame.height { setFrameSize(NSSize(width: width, height: low)) }
        progress = 0
        animator.run(
            duration: duration,
            step: { [weak self] p in
                self?.progress = CGFloat(p)
                self?.needsDisplay = true
            },
            completion: { [weak self] in
                guard let self else { return }
                self.transition = nil
                self.progress = 1
                self.updateLayout(width: self.bounds.width)
                self.needsDisplay = true
            })
        needsDisplay = true
    }

    /// For tests: an animation is running, with how many apps gliding and how many leaving.
    var animationInfo: String {
        lastTransitionInfo + (transition != nil ? String(format: " running %.2f", progress) : "")
    }
    private var lastTransitionInfo = "none"

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
        let cell = CGRect(
            x: from.minX + (target.minX - from.minX) * p, y: from.minY + (target.minY - from.minY) * p,
            width: target.width, height: target.height)
        return (cell, 1, 1)
    }

    // MARK: Zoom (slider, Cmd+= / Cmd+-, pinch, Cmd+scroll: as in the Icons view)

    /// Shows a new icon size immediately, keeping the app under `anchor` (or the current one) in place.
    func previewZoom(_ size: CGFloat, anchor: CGPoint? = nil, commitAfter delay: TimeInterval? = 0.35) {
        let s = min(ZoomLevels.maxSize, max(ZoomLevels.minSize, size))
        let vr = visibleRect
        // Anchor: the app under the pointer (or the current app, or the first one shown), kept at the same spot.
        var anchorIndex = anchor.flatMap { index(at: $0) }
        if anchorIndex == nil { anchorIndex = model.currentURL.flatMap { model.index(of: $0) } }
        if anchorIndex == nil { anchorIndex = model.rows.indices.first { cellRect($0).intersects(vr) } }
        if let i = anchorIndex, i >= model.rows.count { anchorIndex = nil }
        let before = anchorIndex.map { cellRect($0).origin }
        reflowing {
            liveIconSize = s
            updateLayout(width: bounds.width)
            if let i = anchorIndex, let before { scrollGrid(toY: vr.minY + cellRect(i).minY - before.y) }
        }
        needsDisplay = true
        onZoomPreview?(s)
        zoomCommitTimer?.invalidate()
        if let d = delay {
            zoomCommitTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in self?.commitZoom() }
        }
    }

    /// Animates to a size (Cmd+= / Cmd+-), then saves it.
    func animateZoom(to size: CGFloat) {
        let from = iconSize
        zoomAnimator.run(
            duration: 0.16,
            step: { [weak self] p in self?.previewZoom(from + (size - from) * CGFloat(p), commitAfter: nil) },
            completion: { [weak self] in self?.commitZoom() })
    }

    /// Saves the size reached; the tiles are rendered once more, at exactly that size.
    func commitZoom() {
        zoomCommitTimer?.invalidate()
        guard let s = liveIconSize else { return }
        let size = s.rounded()
        let y = visibleRect.minY
        // The rounded size may hold one app more or less per row: that glides too.
        reflowing {
            liveIconSize = nil
            savedIconSize = size
            updateLayout(width: bounds.width)
            scrollGrid(toY: y)
        }
        Settings.shared.appLibraryIconSize = Double(size)
        needsDisplay = true
    }

    /// Another window zoomed its library (or settings were restored): this one takes the same size.
    func savedSizeChanged() {
        let size = CGFloat(Settings.shared.appLibraryIconSize)
        guard size != savedIconSize, liveIconSize == nil else { return }
        reflowing {
            savedIconSize = size
            updateLayout(width: bounds.width)
        }
        tiles = [:]
        needsDisplay = true
        onZoomPreview?(size)
    }

    /// Runs `change` (a zoom step: a layout at another size, maybe scrolled to keep the anchor in place). When the
    /// apps reflow into another number of columns they glide to their new cells as on a resize (the same glide, and
    /// the Icons view's timing), starting from where they were on screen; a running glide carries on, kept on screen
    /// across the scroll, and a further reflow starts from where the apps are drawn at that moment.
    private func reflowing(_ change: () -> Void) {
        let vr = visibleRect, shape = columns
        let before = window != nil && !targets.isEmpty ? currentCells() : [:]
        change()
        let dy = visibleRect.minY - vr.minY
        if columns != shape, !before.isEmpty, !Animator.reducesMotion() {
            glide(from: before.mapValues { $0.offsetBy(dx: 0, dy: dy) }, items: [:], duration: ItemListView.transitionDuration)
        } else if var t = transition, dy != 0 {
            t.from = t.from.mapValues { $0.offsetBy(dx: 0, dy: dy) }
            t.leaving = t.leaving.map { ($0.item, $0.cell.offsetBy(dx: 0, dy: dy)) }
            transition = t
        }
    }

    /// Scrolls the grid so its visible part starts at `y`, as far as it can go (the clip view keeps it in bounds).
    private func scrollGrid(toY y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let p = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)).origin
        guard p != clip.bounds.origin else { return }
        clip.scroll(to: p)
        scroll.reflectScrolledClipView(clip)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        // Cmd+wheel / two-finger scroll zooms smoothly (trackpads) or by Dolphin's steps (mouse wheels).
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            let level = ZoomLevels.continuousLevel(for: iconSize) + Double(event.scrollingDeltaY) * 0.02
            previewZoom(ZoomLevels.size(forContinuousLevel: level), anchor: p)
        } else if event.scrollingDeltaY != 0 {
            previewZoom(ZoomLevels.step(from: iconSize, by: event.scrollingDeltaY > 0 ? 1 : -1), anchor: p)
        }
    }

    override func magnify(with event: NSEvent) {
        // Pinch: continuous zoom around the fingers, saved when the gesture ends.
        let p = convert(event.locationInWindow, from: nil)
        previewZoom(iconSize * (1 + event.magnification), anchor: p, commitAfter: event.phase == .ended || event.phase == .cancelled ? 0 : 0.5)
    }

    /// For tests: how far a running glide has come.
    var glideProgress: CGFloat? { transition != nil ? progress : nil }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Applications" }

    /// The apps on screen, each read by name and opened on "press".
    override func accessibilityChildren() -> [Any]? {
        model.rows.indices.filter { cellRect($0).intersects(visibleRect) }.map { i in
            let item = model.rows[i].item
            return AccessibleRegion(
                in: self, role: .button, label: AppLibrary.displayName(item.url),
                frame: { [weak self] in self?.cellRect(i) ?? .zero },
                selected: { [weak self] in self?.model.selection.contains(item.url) ?? false },
                press: { [weak self] in if let o = self?.owner { o.host?.appsView(o, open: [item]) } })
        }
    }

    // MARK: Geometry (all of it follows the icon size; at 80 pt, the library's first look: 136 pt cells)

    /// Above the icon.
    private var iconTop: CGFloat { min(14, max(6, iconSize * 0.125)) }
    /// Between the icon and its name.
    private var nameGap: CGFloat { min(14, max(6, iconSize * 0.15)) }
    /// The names grow a little with the icons, from 11 pt to 15 pt (12.5 pt at 80), in half points.
    private var nameFontSize: CGFloat { (min(15, max(11, 10.5 + iconSize * 0.025)) * 2).rounded() / 2 }
    private var nameHeight: CGFloat { ceil(nameFontSize * 1.36) }

    private var cell: CGSize {
        CGSize(width: max(96, iconSize + 56), height: iconTop + iconSize + nameGap + nameHeight + 17)
    }

    private func cellRect(_ i: Int) -> CGRect {
        let cell = cell
        return CGRect(
            x: originX + CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * cell.height,
            width: cell.width, height: cell.height)
    }

    private func iconRect(_ i: Int) -> CGRect { iconRect(in: cellRect(i)) }

    private func iconRect(in c: CGRect) -> CGRect {
        CGRect(x: c.midX - iconSize / 2, y: c.minY + iconTop, width: iconSize, height: iconSize)
    }

    private func index(at p: CGPoint) -> Int? {
        guard p.x >= originX, p.y >= 0 else { return nil }
        let col = Int((p.x - originX) / cell.width), row = Int(p.y / cell.height)
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

    /// The shadow follows the icon's size (7 pt blur, 3 pt down at 80 pt).
    private static func shadowBlur(_ size: CGFloat) -> CGFloat { max(1.5, 7 * size / 80) }
    private static func shadowOffset(_ size: CGFloat) -> CGFloat { max(0.5, 3 * size / 80) }
    /// Room around a tile's icon for its shadow.
    private static func tilePad(_ size: CGFloat) -> CGFloat { shadowBlur(size) + shadowOffset(size) }

    /// The size tiles are rendered at: the size itself, or mid-zoom one of the few Dolphin steps (the one at or above
    /// it), drawn scaled down, as the Icons view does. Rendering every tile afresh at each size a zoom passes through
    /// would make its frames far too slow.
    private var renderSize: CGFloat { liveIconSize.map(ZoomLevels.liveRenderSize(for:)) ?? iconSize }

    /// The app's tile at `size`, or, when this frame has no time left to render it, the one of the nearest size
    /// rendered (the larger one first), with the size it has.
    private func tile(for item: FileItem, size: CGFloat) -> (image: NSImage, size: CGFloat) {
        if let t = tiles[size]?[item.url] { return (t, size) }
        if CACurrentMediaTime() > renderDeadline,
            let near = tileSizes.filter({ tiles[$0]?[item.url] != nil }).min(by: { Self.standInCost($0, size) < Self.standInCost($1, size) }),
            let t = tiles[near]?[item.url]
        {
            tilesPending = true
            return (t, near)
        }
        return (renderTile(for: item, size: size), size)
    }

    /// How far a tile of size `s` is from `size` (a larger one, scaled down, looks better than a smaller one scaled up).
    private static func standInCost(_ s: CGFloat, _ size: CGFloat) -> CGFloat { abs(log(s / size)) * (s >= size ? 0.8 : 1) }

    /// The icon with its shadow (a soft one, like the Dock's), `size` points, in pixels for this screen.
    private func renderTile(for item: FileItem, size: CGFloat) -> NSImage {
        let scale = window?.backingScaleFactor ?? 2
        let pad = Self.tilePad(size)
        let side = size + 2 * pad
        let px = Int(ceil(side * scale))
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return icon(for: item) }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = Self.shadowBlur(size)
        shadow.shadowOffset = NSSize(width: 0, height: -Self.shadowOffset(size))
        shadow.set()
        icon(for: item).draw(
            in: CGRect(x: pad, y: pad, width: size, height: size), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return icon(for: item) }
        let t = NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        if tiles[size] == nil {
            tileSizes.append(size)
            if tileSizes.count > 6 { tiles[tileSizes.removeFirst()] = nil }
        }
        tiles[size, default: [:]][item.url] = t
        return t
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let p = progress
        let look = Look(grid: self)
        // Tiles that this frame has no time to render are drawn from another size, and rendered over the next frames.
        renderDeadline = CACurrentMediaTime() + 0.003
        tilesPending = false
        defer {
            renderDeadline = .infinity
            if tilesPending { DispatchQueue.main.async { [weak self] in self?.needsDisplay = true } }
        }
        // Apps leaving the result shrink and fade out quickly, under the ones that stay.
        for l in transition?.leaving ?? [] {
            drawItem(
                l.item, cell: l.cell, look: look, selected: false, hovered: false, focused: focused,
                alpha: max(0, 1 - p * 1.6), scale: 1 - 0.18 * p, dirty: dirtyRect)
        }
        for (i, row) in model.rows.enumerated() {
            let item = row.item
            let place = placement(item.url, target: cellRect(i))
            drawItem(
                item, cell: place.cell, look: look, selected: model.selection.contains(item.url), hovered: hover == i,
                focused: focused, alpha: place.alpha, scale: place.scale, dirty: dirtyRect)
        }
    }

    /// What every app is drawn with at the size shown, worked out once per frame.
    private struct Look {
        let renderSize: CGFloat
        let highlightInset: CGFloat
        let highlightRadius: CGFloat
        let font: NSFont
        /// Names' widths are measured at 12.5 pt; at another size, roughly in proportion.
        let fontScale: CGFloat
        let nameGap: CGFloat
        let nameHeight: CGFloat

        init(grid g: AppsGridView) {
            let s = g.iconSize
            renderSize = g.renderSize
            highlightInset = max(4, (s * 0.11).rounded())
            highlightRadius = max(6, s * 0.225)
            font = AppsGridView.nameFont(g.nameFontSize)
            fontScale = g.nameFontSize / 12.5
            nameGap = g.nameGap
            nameHeight = g.nameHeight
        }
    }

    /// One app: highlight, icon, name and running dot, all in theme colours (like the other views).
    private func drawItem(
        _ item: FileItem, cell: CGRect, look: Look, selected: Bool, hovered: Bool, focused: Bool,
        alpha: CGFloat, scale: CGFloat, dirty: CGRect
    ) {
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
            let bg = NSBezierPath(
                roundedRect: ir.insetBy(dx: -look.highlightInset, dy: -look.highlightInset), xRadius: look.highlightRadius,
                yRadius: look.highlightRadius)
            let fill = selected ? (hovered ? Theme.itemSelectedHoverFill : Theme.itemSelectedFill) : Theme.itemHoverFill
            (selected && !focused ? fill.withAlphaComponent(fill.alphaComponent * 0.6) : fill).setFill()
            bg.fill()
            if selected {
                Theme.itemSelectedOutline.setStroke()
                bg.lineWidth = 1
                bg.stroke()
            }
        }
        // The tile as rendered, scaled into place mid-zoom (its shadow scales with it).
        let tile = tile(for: item, size: look.renderSize)
        let pad = Self.tilePad(tile.size) * iconSize / tile.size
        tile.image.draw(
            in: ir.insetBy(dx: -pad, dy: -pad), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        // The name, on the selection colour when selected.
        let (name, nameW) =
            names[item.url]
            ?? {
                let n = AppLibrary.displayName(item.url)
                let w = ceil((n as NSString).size(withAttributes: [.font: Self.nameFont(12.5)]).width)
                names[item.url] = (n, w)
                return (n, w)
            }()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: look.font, .paragraphStyle: Self.namePara,
            .foregroundColor: selected && focused ? Theme.selectionText : Theme.viewText,
        ]
        let maxW = cell.width - 14
        let textW = min(maxW, ceil(nameW * look.fontScale))
        let textRect = CGRect(x: cell.midX - maxW / 2, y: ir.maxY + look.nameGap, width: maxW, height: look.nameHeight)
        if selected {
            let h = look.nameHeight + 2
            let capsule = CGRect(x: cell.midX - textW / 2 - 7, y: textRect.minY - 1, width: textW + 14, height: h)
            (focused ? Theme.selection : Theme.itemSelectedFill).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: h / 2, yRadius: h / 2).fill()
        }
        (name as NSString).draw(in: textRect, withAttributes: attrs)

        // Running apps get the Dock's dot.
        if running.contains(item.url.standardizedFileURL.path) {
            Theme.viewTextInactive.setFill()
            NSBezierPath(ovalIn: CGRect(x: cell.midX - 2, y: textRect.maxY + 5, width: 4, height: 4)).fill()
        }
    }

    /// The names' font at `size` (half points: a zoom passes through few of them), made once.
    private static func nameFont(_ size: CGFloat) -> NSFont {
        if let f = nameFonts[size] { return f }
        let f = NSFont.systemFont(ofSize: size, weight: .medium)
        nameFonts[size] = f
        return f
    }
    nonisolated(unsafe) private static var nameFonts: [CGFloat: NSFont] = [:]
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
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
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
            event.modifierFlags.intersection([.command, .shift]).isEmpty, event.clickCount == 1
        {
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
        case 123: move(by: -1, extend: event.modifierFlags.contains(.shift)); return  // ←
        case 124: move(by: 1, extend: event.modifierFlags.contains(.shift)); return  // →
        case 126:  // ↑
            if mods.contains(.command) { break }
            move(by: -columns, extend: event.modifierFlags.contains(.shift)); return
        case 125:  // ↓, ⌘↓ opens
            if mods.contains(.command) { openSelection(); return }
            move(by: columns, extend: event.modifierFlags.contains(.shift)); return
        case 36, 76: openSelection(); return  // Return
        case 49: if let o = owner { o.host?.appsViewQuickLook(o) }; return  // Space
        case 53: model.selection = []; needsDisplay = true; return  // Escape
        default: break
        }
        // Letters search, as in Launchpad.
        if mods.isEmpty, let chars = event.characters, let c = chars.unicodeScalars.first,
            CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains(c)
        {
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
