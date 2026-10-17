import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Layout transitions

/// Where the items were drawn just before a change, and pictures of them: the start of a transition. Keyed by
/// `ItemListView.transitionKey`, so the same file matches however its path was spelled.
struct ItemSnapshot {
    /// Each visible item's cell as drawn, in the view's coordinates.
    let rects: [String: CGRect]
    /// Each of them drawn on its own: what leaves fades out from it.
    let images: [String: CGImage]
    /// The part that flies to the other pane of a split view (the whole cell in Icons; icon and name in the list
    /// modes, whose other columns differ between the panes), as a picture.
    let flightImages: [String: CGImage]
    /// The view mode they were drawn in: when it changes (search results show in Details), items crossfade.
    let mode: ViewMode
    /// Where the view's top-left was in the window: the view may move by the time the change shows (a Details
    /// header appearing above it), and the items' start positions move with it, so nothing jumps.
    let originInWindow: CGPoint
}

/// A running transition: items glide from where they were to their new cells, items that went away fade out
/// (drawn from the snapshot), new ones come in. The same in Icons, Compact and Details, which all draw items from
/// `frames`.
struct ItemTransition {
    var from: [String: CGRect]
    var leaving: [(rect: CGRect, image: CGImage)]
    var progress: CGFloat = 0
    /// New items that come in one after another (search results): when each starts, as a fraction of the time.
    var appearDelay: [String: CGFloat] = [:]
    /// Old pictures of moving items whose look changed with the view mode: they fade out as the new look fades in.
    var morph: [String: (image: CGImage, size: CGSize)] = [:]

    /// How far a new item has come in: all at once, or in turn after its delay.
    func appearProgress(_ key: String) -> CGFloat {
        let d = appearDelay[key] ?? 0
        return d >= 1 ? 0 : min(1, max(0, (progress - d) / (1 - d)))
    }
}

/// What a transition is for, as `ItemTransitions.log` records it.
enum TransitionKind: String {
    /// The split view opening: the left pane's items glide to their places, the right pane's fly in from them.
    case splitOpen
    /// The split view closing: the closing pane's items fly back onto the same ones in the pane that stays.
    case splitClose
    /// The filter bar's text changed.
    case filter
    /// Search results came in or went.
    case search
    /// A listing changed under a view that already showed it (Drive's answer after the saved listing, a change made
    /// elsewhere).
    case remote
    /// A resize or a zoom put the items in other places.
    case reflow
}

/// The one owner of a view's item animations (see artifacts/p4/m4/TRANSITIONS.md). Everything that changes what a view
/// shows or where comes through here, whatever the location (a local folder, Google Drive, a search):
/// - `navigate()` when the view goes somewhere else: whatever ran stops;
/// - `itemsDelivered(loading:)` whenever its listing changed, from the first page of a slow listing to the last: a
///   listing only delivers, it never animates on its own;
/// - `change(_:_:)` for a change shown as a glide (filter, search, remote changes, a split's left pane);
/// - `whenItemsArrive(_:)`, `flightPictures()`, `landingPictures(_:)`, `flightStarts(hiding:)`, `flightArrives(_:)`,
///   `flightLanded(_:)`, `flightLeaves(_:)` for the split's flights;
/// - `resized()` and `reflow(_:)` for the layout changing under the items.
/// Only one transition runs at a time per view: while a split's flight is due or running, other changes show at once
/// (the flight already moves the items there), so nothing animates twice.
@MainActor final class ItemTransitions {
    private unowned let list: ItemListView
    /// The transitions started since the view was made (the last 32), for the debug bridge and tests.
    private(set) var log: [TransitionKind] = []
    /// When each of them started (`CACurrentMediaTime`).
    private(set) var logTimes: [CFTimeInterval] = []
    /// The view has its location's items (or knows there are none): set by the first delivery after `navigate()`.
    private var delivered = false
    /// What runs once the items are there (the split's flight into this pane).
    private var arrival: (() -> Void)?
    /// A flight brings this view's items in: other changes don't animate meanwhile.
    private var flying = false

    init(list: ItemListView) { self.list = list }

    /// Whether a change would animate now (a window to show it in, no Reduce Motion, not a huge folder).
    var animates: Bool { list.animates }

    /// The view shows another location: what ran stops, and the next delivery is that location's first.
    func navigate() {
        list.stopTransitions()
        delivered = false
        arrival = nil
        flying = false
    }

    /// The listing changed (its first page, its whole contents, a reload). `loading`: more is coming.
    func itemsDelivered(loading: Bool) {
        guard !delivered, !list.model.rows.isEmpty || !loading else { return }
        delivered = true
        if let run = arrival {
            arrival = nil
            run()
        }
    }

    /// Runs `run` once the view has its items: at once if it has them (a listing saved from before), else on their
    /// first delivery, which may be the first page of a slow listing. Until then nothing of them is shown moving.
    func whenItemsArrive(_ run: @escaping () -> Void) {
        if delivered { run() } else { arrival = run }
    }

    /// Applies `apply`, which changes what's listed or where, the items gliding from where they were: those that went
    /// away fade out, new ones grow in. `cascade`: new ones come in one after another (search results). `pictures`:
    /// false when the change only adds items (nothing to fade out), which is quicker to start.
    func change(
        _ kind: TransitionKind, duration: TimeInterval = ItemListView.transitionDuration,
        curve: @escaping (Double) -> Double = Animator.easeOutCubic, cascade: Bool = false, pictures: Bool = true, _ apply: () -> Void
    ) {
        let start = flying || arrival != nil ? nil : list.snapshotForTransition(pictures: pictures)
        apply()
        guard let start else { return }
        record(kind)
        list.animateLayoutChange(from: start, duration: duration, curve: curve, cascade: cascade)
    }

    /// The pictures a flight leaving this view starts from (its visible items, as drawn now); nil when nothing would
    /// animate.
    func flightPictures() -> [String: CGImage]? { list.snapshotForTransition()?.flightImages }

    /// The items `keys` as this view will show them once a flight lands here (its own icon size, row height and
    /// layout): the copies turn into these on the way, so they land as exactly what's drawn there.
    func landingPictures(_ keys: [String]) -> [String: CGImage] {
        if list.frames.count != list.model.rows.count { list.computeLayout() }
        var out: [String: CGImage] = [:]
        for k in keys {
            if let i = list.row(forKey: k), let image = list.picture(ofRow: i, part: list.flightPart(i)) { out[k] = image }
        }
        return out
    }

    /// A flight is about to bring `keys` here: they stay hidden until it lands; the view's other items come in where
    /// they are.
    func flightStarts(hiding keys: Set<String>) {
        flying = true
        record(.splitOpen)
        list.animateAppearing(except: keys)
    }

    /// A flight brings `keys` back onto items this view already shows (the split closing): they're hidden until it
    /// lands, the copies standing in for them.
    func flightArrives(_ keys: Set<String>) {
        flying = true
        list.transitionHidden.formUnion(keys)
        list.needsDisplay = true
    }

    /// The flight landed on `keys`: they show where it put them, at once. `completion` (which removes the copies) runs
    /// in the same turn, so no frame shows both or neither; the copies' last picture is these items as drawn here.
    func flightLanded(_ keys: Set<String>, completion: () -> Void) {
        flying = false
        list.transitionHidden.subtract(keys)
        list.needsDisplay = true
        completion()
    }

    /// The flight was cut short (the split closed while it ran): what it hid shows again where it is.
    func flightCancelled() {
        guard flying || !list.transitionHidden.isEmpty else { return }
        flying = false
        list.transitionHidden = []
        list.needsDisplay = true
    }

    /// `keys` leave this view on a flight (the pane closing): they're no longer drawn here.
    func flightLeaves(_ keys: Set<String>) {
        record(.splitClose)
        list.transitionHidden.formUnion(keys)
        list.needsDisplay = true
    }

    /// The view was resized (window, split pane, panel): items that change places glide there. Not while a flight
    /// brings them in: it reads where they are at every frame, so it follows them by itself.
    func resized() {
        guard !flying, arrival == nil else { return list.relayout() }
        if list.resized() { record(.reflow) }
    }

    /// Runs `change` (a zoom step); items it puts in other places glide there.
    func reflow(_ change: () -> Void) {
        guard !flying, arrival == nil else { return change() }
        if list.reflowing(change) { record(.reflow) }
    }

    /// The view was laid out for a coming width (`layoutWidthOverride`) while its pane moved; it has that width now.
    /// Its container is laid out first, so the items are placed at the width they really have, and don't move again.
    func releaseWidth() {
        guard list.layoutWidthOverride != nil else { return }
        list.window?.contentView?.layoutSubtreeIfNeeded()
        list.layoutWidthOverride = nil
    }

    private func record(_ kind: TransitionKind) {
        log.append(kind)
        logTimes.append(CACurrentMediaTime())
        if log.count > 32 {
            log.removeFirst(log.count - 32)
            logTimes.removeFirst(logTimes.count - 32)
        }
    }
}

extension ItemListView {
    /// AppsGridView's glides, until it joins `Motion` (after R-9).
    static let transitionDuration = Motion.glide
    /// Beyond this many rows a change is shown at once: every frame would draw a large view.
    private static let maxAnimatedRows = 3000

    /// The same file however it's spelled: searches report /private/tmp/… for what the folder lists as /tmp/….
    static func transitionKey(_ url: URL) -> String { FilePath.key(url) }

    func key(ofRow i: Int) -> String { Self.transitionKey(model.rows[i].item.url) }

    /// The row showing the item `k`, if any.
    func row(forKey k: String) -> Int? {
        if rowKeys.count != model.rows.count {
            rowKeys = Dictionary(model.rows.indices.map { (key(ofRow: $0), $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let i = rowKeys[k], i < frames.count, i < model.rows.count else { return nil }
        return i
    }

    fileprivate var animates: Bool { window != nil && !Animator.reducesMotion() && model.rows.count <= Self.maxAnimatedRows }

    /// Stops whatever runs (the view goes somewhere else): items are drawn where they are.
    func stopTransitions() {
        transitionAnimator.stop()
        transition = nil
        transitionHidden = []
        needsDisplay = true
    }

    /// The visible items as drawn now (mid-transition included), with pictures of them; nil when nothing would
    /// animate (no window, Reduce Motion, a very large folder). Without `pictures`, only where they are: enough when
    /// nothing will leave or change its look (items are only added), and much quicker.
    fileprivate func snapshotForTransition(pictures: Bool = true) -> ItemSnapshot? {
        guard animates else { return nil }
        if frames.count != model.rows.count { computeLayout() }
        let vr = visibleRect
        guard vr.width > 1, vr.height > 1 else { return nil }
        var rects: [String: CGRect] = [:], images: [String: CGImage] = [:], flightImages: [String: CGImage] = [:]
        for i in transitionIndexes(in: vr) {
            let k = key(ofRow: i)
            rects[k] = shownFrame(i)
            guard pictures else { continue }
            images[k] = picture(ofRow: i)
            flightImages[k] = mode == .icons ? images[k] : picture(ofRow: i, part: flightPart(i))
        }
        return ItemSnapshot(
            rects: rects, images: images, flightImages: flightImages, mode: mode, originInWindow: convert(CGPoint.zero, to: nil))
    }

    /// The part of row `i` that flies between split panes, where it is in the final layout.
    fileprivate func flightPart(_ i: Int) -> CGRect {
        mode == .icons ? frames[i] : iconRect(i).union(nameTextRect(i)).insetBy(dx: -4, dy: -2)
    }

    /// That part where it's drawn at this moment.
    func flightRect(_ i: Int) -> CGRect {
        let shown = shownFrame(i), target = frames[i]
        return flightPart(i).offsetBy(dx: shown.minX - target.minX, dy: shown.minY - target.minY)
    }

    /// Animates from `start` to the current layout (call after the model and the layout changed).
    /// `cascade`: new items come in one after another, in order, instead of all together (search results).
    fileprivate func animateLayoutChange(
        from start: ItemSnapshot, duration: TimeInterval = ItemListView.transitionDuration,
        curve: @escaping (Double) -> Double = Animator.easeOutCubic, cascade: Bool = false
    ) {
        if frames.count != model.rows.count { computeLayout() }
        window?.contentView?.layoutSubtreeIfNeeded()
        // The start positions as seen in the window, in today's coordinates of the view.
        let then = convert(start.originInWindow, from: nil)
        let rects = start.rects.mapValues { $0.offsetBy(dx: then.x, dy: then.y) }
        let now = Set(model.rows.indices.map(key(ofRow:)))
        let leaving = rects.compactMap { k, r -> (rect: CGRect, image: CGImage)? in
            guard !now.contains(k), let img = start.images[k] else { return nil }
            return (r, img)
        }
        var t = ItemTransition(from: rects.filter { now.contains($0.key) }, leaving: leaving)
        if start.mode != mode {
            for (k, r) in t.from { if let img = start.images[k] { t.morph[k] = (img, r.size) } }
        }
        if cascade {
            let arriving = candidateIndexes(in: visibleRect).map(key(ofRow:)).filter { t.from[$0] == nil }
            for (n, k) in arriving.enumerated() { t.appearDelay[k] = min(0.5, CGFloat(n) * 0.035) }
        }
        transition = t
        runTransition(duration: duration, curve: curve)
    }

    /// The view was resized (window, split pane, panel): laid out again. Items that change places (another number of
    /// columns in Icons, of rows per column in Compact) glide there instead of jumping; a resize that keeps them in
    /// place is shown at once, so they never trail the pointer. True when they glide.
    fileprivate func resized() -> Bool {
        guard mode != .details, layoutWidthOverride == nil, animates, frames.count == model.rows.count, !frames.isEmpty else {
            computeLayout()
            return false
        }
        let vr = visibleRect.insetBy(dx: -40, dy: -40)
        let before = Dictionary(transitionIndexes(in: vr).map { (key(ofRow: $0), shownFrame($0)) }, uniquingKeysWith: { a, _ in a })
        let old = frames
        computeLayout()
        // A running glide keeps going to the new places by itself; a new one starts only when the layout reflows.
        let reflowed = zip(old, frames).contains { abs($0.minX - $1.minX) > 24 || abs($0.minY - $1.minY) > 24 }
        guard reflowed, !before.isEmpty, frames.count == old.count else {
            needsDisplay = true
            return false
        }
        transition = ItemTransition(from: before, leaving: [])
        runTransition(duration: Motion.glide)
        return true
    }

    /// Runs `change` (a zoom step: a layout at another icon size, maybe scrolled to keep the anchor in place). When it
    /// reflows the items (another number of columns in Icons, of rows per column in Compact), they glide to their new
    /// cells as in `resized()`, starting from where they were on screen; a running glide carries on, kept on screen
    /// across the scroll. True when a new glide started.
    fileprivate func reflowing(_ change: () -> Void) -> Bool {
        guard mode != .details, layoutWidthOverride == nil, animates, frames.count == model.rows.count, !frames.isEmpty else {
            change()
            return false
        }
        let vr = visibleRect
        let before = Dictionary(
            transitionIndexes(in: vr.insetBy(dx: -40, dy: -40)).map { (key(ofRow: $0), shownFrame($0)) }, uniquingKeysWith: { a, _ in a })
        let shape = (columns, rowsPerColumn), count = frames.count
        change()
        // Where the view scrolled to: what was on screen stays there.
        let dx = visibleRect.minX - vr.minX, dy = visibleRect.minY - vr.minY
        let reflowed = mode == .icons ? columns != shape.0 : rowsPerColumn != shape.1
        if reflowed, !before.isEmpty, frames.count == count {
            transition = ItemTransition(from: before.mapValues { $0.offsetBy(dx: dx, dy: dy) }, leaving: [])
            runTransition(duration: Motion.glide)
            return true
        }
        if var t = transition, dx != 0 || dy != 0 {
            t.from = t.from.mapValues { $0.offsetBy(dx: dx, dy: dy) }
            t.leaving = t.leaving.map { ($0.rect.offsetBy(dx: dx, dy: dy), $0.image) }
            transition = t
        }
        return false
    }

    /// Lets the visible items come in where they are (a view that just got its items), except `except` (keys).
    fileprivate func animateAppearing(except: Set<String> = [], duration: TimeInterval = ItemListView.transitionDuration) {
        guard animates else { return }
        transitionHidden = except
        transition = ItemTransition(from: [:], leaving: [])
        runTransition(duration: duration)
    }

    fileprivate func runTransition(duration: TimeInterval, curve: @escaping (Double) -> Double = Animator.easeOutCubic) {
        transitionAnimator.run(
            duration: duration, curve: curve,
            step: { [weak self] p in
                self?.transition?.progress = CGFloat(p)
                self?.needsDisplay = true
            },
            completion: { [weak self] in
                self?.transition = nil
                self?.needsDisplay = true
            })
    }

    /// Row `i`'s cell where it's drawn at this moment of the transition.
    func shownFrame(_ i: Int) -> CGRect {
        let target = frames[i]
        guard let t = transition, let from = t.from[key(ofRow: i)] else { return target }
        return CGRect(origin: Motion.lerp(from.origin, target.origin, t.progress), size: target.size)
    }

    /// Rows to draw in `rect`. During a transition: every row on its way, picked by where it's drawn at this
    /// moment (AppKit redraws in tiles, and a row passing through a tile must be drawn there too).
    func transitionIndexes(in rect: CGRect) -> [Int] {
        guard let t = transition, !t.from.isEmpty else { return candidateIndexes(in: rect) }
        var rows = Set(candidateIndexes(in: visibleRect.insetBy(dx: -40, dy: -40)))
        for k in t.from.keys { if let i = row(forKey: k) { rows.insert(i) } }
        return rows.filter { shownFrame($0).insetBy(dx: -40, dy: -4).intersects(rect) }.sorted()
    }

    /// Draws row `i` where the transition has it: moved by its offset, coming in when new, hidden while another
    /// view flies it here.
    func drawItemInTransition(_ i: Int, draw: (Int) -> Void) {
        let k = key(ofRow: i)
        if transitionHidden.contains(k) { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return draw(i) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        guard let t = transition else { return draw(i) }
        let target = frames[i]
        let shown = shownFrame(i)
        ctx.translateBy(x: shown.minX - target.minX, y: shown.minY - target.minY)
        if let m = t.morph[k] {
            // The old look travels with the new one: it holds through the first part, the new one takes over in the
            // second (a plain crossfade shows the new look's small parts too early, like a row's icon in a big cell).
            let p = t.progress
            let old = CGRect(origin: target.origin, size: m.size)
            NSImage(cgImage: m.image, size: m.size).draw(
                in: old, from: .zero, operation: .sourceOver, fraction: 1 - Motion.smoothstep(0.25, 0.8, p), respectFlipped: true, hints: nil)
            ctx.setAlpha(Motion.smoothstep(0.35, 0.9, p))
        }
        if t.from[k] == nil {
            let a = t.appearProgress(k)
            guard a > 0 else { return }
            if mode == .icons {
                let s = Motion.appearScale(a)
                ctx.translateBy(x: target.midX, y: target.midY)
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: -target.midX, y: -target.midY)
            } else {
                // A row (wide): slides up a little while fading in; growing from its middle would look odd.
                ctx.translateBy(x: 0, y: 10 * (1 - a))
            }
            ctx.setAlpha(a)
        }
        draw(i)
    }

    /// Items that went away, drawn from the snapshot: they fade out quickly under the others (and shrink, in Icons).
    func drawLeavingItems() {
        guard let t = transition, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (a, shrink) = Motion.leave(t.progress)
        guard a > 0.01 else { return }
        let s: CGFloat = mode == .icons ? shrink : 1
        for l in t.leaving {
            ctx.saveGState()
            ctx.translateBy(x: l.rect.midX, y: l.rect.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -l.rect.midX, y: -l.rect.midY)
            NSImage(cgImage: l.image, size: l.rect.size).draw(
                in: l.rect, from: .zero, operation: .sourceOver, fraction: a, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
    }
}
