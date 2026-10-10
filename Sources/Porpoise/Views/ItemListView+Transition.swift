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

extension ItemListView {
    static let transitionDuration: TimeInterval = 0.3
    /// Beyond this many rows a change is shown at once: every frame would draw a large view.
    private static let maxAnimatedRows = 3000

    /// The same file however it's spelled: searches report /private/tmp/… for what the folder lists as /tmp/….
    static func transitionKey(_ url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        // Items' URLs are already standard (made from paths); standardizing thousands of them each change would cost.
        let p = url.path
        return p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p
    }

    func key(ofRow i: Int) -> String { Self.transitionKey(model.rows[i].item.url) }

    /// The row showing the item `k`, if any.
    func row(forKey k: String) -> Int? {
        if rowKeys.count != model.rows.count {
            rowKeys = Dictionary(model.rows.indices.map { (key(ofRow: $0), $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let i = rowKeys[k], i < frames.count, i < model.rows.count else { return nil }
        return i
    }

    private var animates: Bool {
        window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && model.rows.count <= Self.maxAnimatedRows
    }

    /// The visible items as drawn now (mid-transition included), with pictures of them; nil when nothing would
    /// animate (no window, Reduce Motion, a very large folder).
    func snapshotForTransition() -> ItemSnapshot? {
        guard animates else { return nil }
        if frames.count != model.rows.count { computeLayout() }
        let vr = visibleRect
        guard vr.width > 1, vr.height > 1 else { return nil }
        var rects: [String: CGRect] = [:], images: [String: CGImage] = [:], flightImages: [String: CGImage] = [:]
        for i in transitionIndexes(in: vr) {
            let k = key(ofRow: i)
            rects[k] = shownFrame(i)
            images[k] = picture(ofRow: i)
            flightImages[k] = mode == .icons ? images[k] : picture(ofRow: i, part: flightPart(i))
        }
        return ItemSnapshot(
            rects: rects, images: images, flightImages: flightImages, mode: mode, originInWindow: convert(CGPoint.zero, to: nil))
    }

    /// The part of row `i` that flies between split panes, where it is in the final layout.
    private func flightPart(_ i: Int) -> CGRect {
        mode == .icons ? frames[i] : iconRect(i).union(nameTextRect(i)).insetBy(dx: -4, dy: -2)
    }

    /// That part where it's drawn at this moment.
    func flightRect(_ i: Int) -> CGRect {
        let shown = shownFrame(i), target = frames[i]
        return flightPart(i).offsetBy(dx: shown.minX - target.minX, dy: shown.minY - target.minY)
    }

    /// Animates from `start` to the current layout (call after the model and the layout changed).
    /// `cascade`: new items come in one after another, in order, instead of all together (search results).
    func animateLayoutChange(
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

    /// Lets the visible items come in where they are (a view that just got its items), except `except` (keys).
    func animateAppearing(except: Set<String> = [], duration: TimeInterval = ItemListView.transitionDuration) {
        guard animates else { return }
        transitionHidden = except
        transition = ItemTransition(from: [:], leaving: [])
        runTransition(duration: duration)
    }

    private func runTransition(duration: TimeInterval, curve: @escaping (Double) -> Double = Animator.easeOutCubic) {
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

    /// Items another view flew in (keys): they fade in where they landed, then `completion`.
    func reveal(_ keys: Set<String>, completion: @escaping () -> Void = {}) {
        transitionHidden.subtract(keys)
        guard animates, !keys.isEmpty else {
            needsDisplay = true
            return completion()
        }
        revealing = (keys, 0)
        revealAnimator.run(
            duration: 0.16,
            step: { [weak self] p in
                self?.revealing?.progress = CGFloat(p)
                self?.needsDisplay = true
            },
            completion: { [weak self] in
                self?.revealing = nil
                self?.needsDisplay = true
                completion()
            })
    }

    /// Row `i`'s cell where it's drawn at this moment of the transition.
    func shownFrame(_ i: Int) -> CGRect {
        let target = frames[i]
        guard let t = transition, let from = t.from[key(ofRow: i)] else { return target }
        let p = t.progress
        return CGRect(
            x: from.minX + (target.minX - from.minX) * p, y: from.minY + (target.minY - from.minY) * p,
            width: target.width, height: target.height)
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
    /// view flies it here, fading in once it landed.
    func drawItemInTransition(_ i: Int, draw: (Int) -> Void) {
        let k = key(ofRow: i)
        if transitionHidden.contains(k) { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return draw(i) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let r = revealing, r.keys.contains(k) { ctx.setAlpha(r.progress) }
        guard let t = transition else { return draw(i) }
        let target = frames[i]
        let shown = shownFrame(i)
        ctx.translateBy(x: shown.minX - target.minX, y: shown.minY - target.minY)
        if let m = t.morph[k] {
            // The old look travels with the new one: it holds through the first part, the new one takes over in the
            // second (a plain crossfade shows the new look's small parts too early, like a row's icon in a big cell).
            let p = t.progress
            let smooth = { (a: CGFloat, b: CGFloat) -> CGFloat in
                let x = min(1, max(0, (p - a) / (b - a))); return x * x * (3 - 2 * x)
            }
            let old = CGRect(origin: target.origin, size: m.size)
            NSImage(cgImage: m.image, size: m.size).draw(
                in: old, from: .zero, operation: .sourceOver, fraction: 1 - smooth(0.25, 0.8), respectFlipped: true, hints: nil)
            ctx.setAlpha(smooth(0.35, 0.9))
        }
        if t.from[k] == nil {
            let a = t.appearProgress(k)
            guard a > 0 else { return }
            if mode == .icons {
                // Grows from 82 % while fading in.
                let s = 0.82 + 0.18 * a
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
        let a = max(0, 1 - t.progress * 1.6)
        guard a > 0.01 else { return }
        let s: CGFloat = mode == .icons ? 1 - 0.18 * t.progress : 1
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
