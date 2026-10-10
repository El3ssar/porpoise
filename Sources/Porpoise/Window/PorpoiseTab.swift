import AppKit
import PorpoiseCore
import PorpoiseServices

/// One tab: a primary view and an optional secondary view side by side (Dolphin's DolphinTabPage).
///
/// The panes and the handle between them are laid out by hand from a single `splitFraction`, so the drawn
/// line, its hit area and both panes always move together, during the open/close animation as well as while
/// dragging or resizing the window. (An NSSplitView here would keep its own divider state, redraw its line only
/// when it decides to, and re-adjust the panes in its own layout pass, fighting the animation.)
final class PorpoiseTab: NSView {
    private(set) var primary: ViewContainer
    private(set) var secondary: ViewContainer?
    let navigators: [BreadcrumbView] = [BreadcrumbView(), BreadcrumbView()]
    private(set) var activeIsSecondary = false
    var customTitle: String?

    private let handle = SplitHandleView()
    /// Handle position as a fraction of the width, so it stays proportional when the window resizes.
    private var splitFraction: CGFloat = 0.5
    /// Pane being closed: still visible while it shrinks away (Dolphin keeps such "zombie" views).
    private var closing: ViewContainer?
    private var closingOnLeft = false
    private let animator = Animator()
    /// Copies of the left pane's items flying into the right one as the split opens.
    private var flightOverlay: SplitFlightOverlay?
    private let flightAnimator = Animator()
    private static let flightDuration: TimeInterval = 0.42
    /// The right list's width once the split has opened: which of its items fly in (in Compact, items flow in
    /// columns, and the still narrow pane would show only the first).
    private var openingRightWidth: CGFloat?
    /// Handle position the user chose last; reopening the split returns to it (m_splitterLastPosition).
    private static var lastFraction: CGFloat = 0.5

    /// Narrowest a pane can be dragged (QSplitter keeps views usable).
    private static let minPaneWidth: CGFloat = 160
    private static let openDuration: TimeInterval = 0.28
    private static let closeDuration: TimeInterval = 0.24
    private static let resetDuration: TimeInterval = 0.2

    var active: ViewContainer { activeIsSecondary ? (secondary ?? primary) : primary }
    var inactive: ViewContainer? { secondary == nil ? nil : (activeIsSecondary ? primary : secondary) }
    var isSplit: Bool { secondary != nil }
    var containers: [ViewContainer] { [primary] + (secondary.map { [$0] } ?? []) }

    init(url: URL) {
        primary = ViewContainer(url: url)
        super.init(frame: .zero)
        addSubview(primary)
        addSubview(handle)
        handle.onDrag = { [weak self] x in self?.dragHandle(to: x) }
        handle.onDoubleClick = { [weak self] in self?.resetSplitterSizes() }
        updateActive()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutPanes()
    }

    /// Places the panes and the handle at `splitFraction`; the only place their frames are set.
    private func layoutPanes() {
        defer { NotificationCenter.default.post(name: .splitResized, object: self) }
        let b = bounds
        let left: ViewContainer, right: ViewContainer
        if let s = secondary {
            (left, right) = (primary, s)
        } else if let z = closing {
            (left, right) = closingOnLeft ? (z, primary) : (primary, z)
        } else {
            primary.frame = b
            handle.isHidden = true
            return
        }
        let line = SplitHandleView.lineWidth
        let x = (b.width * splitFraction).rounded()
        left.frame = CGRect(x: 0, y: 0, width: x, height: b.height)
        right.frame = CGRect(x: x + line, y: 0, width: max(0, b.width - x - line), height: b.height)
        handle.isHidden = false
        handle.frame = CGRect(x: x - SplitHandleView.grabMargin, y: 0, width: SplitHandleView.width, height: b.height)
    }

    private func setFraction(_ f: CGFloat) {
        splitFraction = f
        layoutPanes()
    }

    // MARK: - Handle

    /// Drag on the handle; `windowX` is where the line should go, in window coordinates.
    private func dragHandle(to windowX: CGFloat) {
        guard secondary != nil, bounds.width > 0 else { return }
        animator.stop()
        let x = convert(CGPoint(x: windowX, y: 0), from: nil).x
        let minX = Self.minPaneWidth
        let maxX = bounds.width - Self.minPaneWidth - SplitHandleView.lineWidth
        let clamped = minX < maxX ? min(max(x, minX), maxX) : bounds.width / 2
        setFraction(clamped / bounds.width)
        Self.lastFraction = splitFraction
    }

    /// Double-click on the handle: back to equal halves (DolphinTabPageSplitterHandle).
    func resetSplitterSizes() {
        guard secondary != nil else { return }
        Self.lastFraction = 0.5
        animateFraction(to: 0.5, duration: Self.resetDuration, curve: Animator.easeOutCubic)
    }

    private func animateFraction(
        to target: CGFloat, duration: TimeInterval, curve: @escaping (Double) -> Double,
        completion: (() -> Void)? = nil
    ) {
        let from = splitFraction
        animator.run(
            duration: duration, curve: curve,
            step: { [weak self] p in
                self?.setFraction(from + (target - from) * CGFloat(p))
            }, completion: completion)
    }

    // MARK: - Open / close

    /// Opens the second view (Dolphin F3): it slides in from the right edge to its last width (OutCubic).
    func openSplit(url: URL? = nil, animated: Bool = true) {
        guard secondary == nil else { return }
        finishClosing()
        let s = ViewContainer(url: url ?? active.url)
        s.delegate = primary.delegate
        secondary = s
        addSubview(s, positioned: .below, relativeTo: handle)
        setActive(secondary: true)
        guard animated, bounds.width > 0 else {
            setFraction(Self.lastFraction)
            return
        }
        // Both panes are laid out at their final widths from the start: the left one's items glide straight to
        // their places while the handle moves (instead of jumping a column at a time), and the right one, empty,
        // receives copies of them that fly over once it has listed its folder (its own style and order apply).
        let leftWidth = (bounds.width * Self.lastFraction).rounded()
        let rightWidth = bounds.width - leftWidth - SplitHandleView.lineWidth
        if let start = primary.list.snapshotForTransition() {
            // Only Icons rearranges with the width; Details and Compact just follow it smoothly.
            if primary.list.mode == .icons {
                primary.list.layoutWidthOverride = primary.listWidth(forPaneWidth: leftWidth)
                primary.list.animateLayoutChange(from: start, duration: Self.openDuration)
            }
            if s.list.mode == .icons { s.list.layoutWidthOverride = primary.listWidth(forPaneWidth: rightWidth) }
            openingRightWidth = primary.listWidth(forPaneWidth: rightWidth)
            s.onNextLoad = { [weak self, weak s] in
                guard let self, let s, s === self.secondary else { return }
                self.flyItems(into: s)
            }
        }
        setFraction(1)
        animateFraction(to: Self.lastFraction, duration: Self.openDuration, curve: Animator.easeOutCubic) { [weak self] in
            guard let self else { return }
            self.primary.list.layoutWidthOverride = nil
            if self.flightOverlay == nil { self.secondary?.list.layoutWidthOverride = nil }
        }
    }

    /// Opening: copies of the left pane's visible items fly to their places in `right`; its other items come in.
    private func flyItems(into right: ViewContainer) {
        let list = right.list
        guard let start = primary.list.snapshotForTransition() else { return }
        if list.frames.count != list.model.rows.count { list.computeLayout() }
        let shown = CGRect(
            x: 0, y: 0, width: list.layoutWidthOverride ?? openingRightWidth ?? list.visibleWidth, height: list.visibleHeight)
        openingRightWidth = nil
        let keys = list.candidateIndexes(in: shown).map(list.key(ofRow:)).filter { start.flightImages[$0] != nil }
        list.animateAppearing(except: Set(keys))
        fly(keys, images: start.flightImages, from: primary.list, to: list, duration: Self.flightDuration) { [weak self, weak list] done in
            list?.reveal(Set(keys)) { done() }
            if self?.animator.isRunning == false { list?.layoutWidthOverride = nil }
        }
    }

    /// Closing: copies of the closing pane's visible items fly back onto the same items in the pane that stays,
    /// and merge into them; what's only in the closing pane leaves with it.
    private func flyItems(backFrom closing: ItemListView, to remaining: ItemListView) {
        guard let start = closing.snapshotForTransition() else { return }
        let keys = start.flightImages.keys.filter { remaining.row(forKey: $0) != nil }
        closing.transitionHidden.formUnion(keys)
        closing.needsDisplay = true
        fly(Array(keys), images: start.flightImages, from: closing, to: remaining, duration: Self.closeDuration, fadesIntoTarget: true) { done in
            done()
        }
    }

    /// Draws copies of the items `keys` travelling from where `source` shows them to where `target` shows them, both
    /// read at every frame (the panes and their items move meanwhile). `landed` gets a function that removes the
    /// copies, to call once whatever replaces them is shown.
    private func fly(
        _ keys: [String], images: [String: CGImage], from source: ItemListView, to target: ItemListView, duration: TimeInterval,
        fadesIntoTarget: Bool = false, landed: @escaping (_ done: @escaping () -> Void) -> Void
    ) {
        endFlights()
        guard !keys.isEmpty else { return landed {} }
        let overlay = SplitFlightOverlay(frame: bounds)
        overlay.flights = keys.compactMap { k in
            guard let img = images[k], let i = source.row(forKey: k) else { return nil }
            return .init(key: k, image: img, size: source.flightRect(i).size)
        }
        func place(_ list: ItemListView) -> (String) -> CGRect? {
            { [weak list, weak overlay] k in
                guard let list, let overlay, let i = list.row(forKey: k) else { return nil }
                return list.convert(list.flightRect(i), to: overlay)
            }
        }
        overlay.fadesIntoTarget = fadesIntoTarget
        overlay.source = place(source)
        overlay.target = place(target)
        addSubview(overlay, positioned: .above, relativeTo: nil)
        flightOverlay = overlay
        flightAnimator.run(
            duration: duration, curve: Animator.easeInOutCubic,
            step: { [weak overlay] p in overlay?.progress = CGFloat(p) },
            completion: { [weak self, weak overlay] in
                landed { if self?.flightOverlay === overlay { self?.endFlights() } }
            })
    }

    private func endFlights() {
        flightAnimator.stop()
        flightOverlay?.removeFromSuperview()
        flightOverlay = nil
    }

    /// Closes one view of the split (Dolphin's CloseSplitViewChoice); the closed view shrinks away (InCubic).
    func closeSplit(closeActive: Bool? = nil, animated: Bool = true) {
        guard let s = secondary else { return }
        let closeSecondary: Bool
        if let closeActive {
            closeSecondary = closeActive == activeIsSecondary
        } else {
            switch Settings.shared.closeSplitChoice {
            case .active: closeSecondary = activeIsSecondary
            case .inactive: closeSecondary = !activeIsSecondary
            case .right: closeSecondary = true
            }
        }
        let zombie = closeSecondary ? s : primary
        if !closeSecondary { primary = s }
        secondary = nil
        activeIsSecondary = false
        updateActive()
        zombie.isActive = false
        closing = zombie
        closingOnLeft = !closeSecondary
        guard animated, bounds.width > 0 else {
            finishClosing()
            return
        }
        // The mirror of opening: the pane that stays is laid out at its full width at once, its items gliding to
        // their places as it grows; the closing one keeps its layout while it shrinks away, and its items fly back
        // onto the same ones in the pane that stays.
        if let start = primary.list.snapshotForTransition() {
            // Only Icons rearranges with the width; Details and Compact just follow it smoothly.
            if zombie.list.mode == .icons { zombie.list.layoutWidthOverride = zombie.list.visibleWidth }
            if primary.list.mode == .icons {
                primary.list.layoutWidthOverride = primary.listWidth(forPaneWidth: bounds.width)
                primary.list.animateLayoutChange(from: start, duration: Self.closeDuration)
            }
            flyItems(backFrom: zombie.list, to: primary.list)
        }
        animateFraction(to: closeSecondary ? 1 : 0, duration: Self.closeDuration, curve: Animator.easeInCubic) { [weak self] in
            self?.finishClosing()
        }
    }

    /// Drops the zombie pane (end of the close animation, or a new split opening before it ended).
    private func finishClosing() {
        animator.stop()
        endFlights()
        primary.list.layoutWidthOverride = nil
        guard let z = closing else { return }
        z.removeFromSuperview()
        closing = nil
        layoutPanes()
    }

    // MARK: - Active view

    func setActive(secondary: Bool) {
        activeIsSecondary = secondary && self.secondary != nil
        updateActive()
    }

    func updateActive() {
        primary.isActive = !activeIsSecondary || secondary == nil
        secondary?.isActive = activeIsSecondary
        navigators[0].isActive = primary.isActive
        navigators[1].isActive = activeIsSecondary
    }

    /// Pane x-ranges in window coordinates (for aligning toolbar navigators).
    var paneRanges: [ClosedRange<CGFloat>] {
        containers.map { c in
            let r = c.convert(c.bounds, to: nil)
            return r.minX...r.maxX
        }
    }

    // MARK: - Title and icon

    /// Tab title; in a split the inactive view's name is in parentheses, like Dolphin.
    var title: String { title(markingInactive: true) }

    /// Title without the parentheses (for the window title).
    var plainTitle: String { title(markingInactive: false) }

    private func title(markingInactive: Bool) -> String {
        if let customTitle { return customTitle }
        guard let s = secondary else { return Self.name(of: primary) }
        let (l, r) = (Self.name(of: primary), Self.name(of: s))
        guard markingInactive else { return "\(l) | \(r)" }
        return activeIsSecondary ? "(\(l)) | \(r)" : "\(l) | (\(r))"
    }

    private static func name(of c: ViewContainer) -> String {
        let u = c.url
        if let p = PlacesModel.shared.title(for: u) { return p }
        if u.scheme == "recent" { return u.path == "/files" ? "Recent Files" : "Recent Locations" }
        if u.scheme == "network" { return "Network" }
        if !u.isFileURL { return RemoteFS.displayName(for: u) }
        return u.path == "/" ? "/" : u.lastPathComponent
    }

    var iconName: String {
        let u = active.url
        if u.isFileURL { return IconTheme.folderIconName(u) }
        if u.scheme == "network" { return "network-workgroup" }
        if u.scheme == "adb" { return "smartphone" }
        return RemoteFS.isRemote(u) ? "folder-remote" : "document-open-recent"
    }
}

// MARK: - Split handle

/// The 1 pt line between the two panes, with a slightly wider invisible grab area (like a thin NSSplitView
/// divider). Drag moves it, double-click resets it.
private final class SplitHandleView: NSView {
    static let lineWidth: CGFloat = 1
    /// Extra grab area on each side of the line.
    static let grabMargin: CGFloat = 2
    static let width = lineWidth + 2 * grabMargin

    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Pointer offset from the line when the drag started, so the line doesn't jump under the pointer.
    private var grabOffset: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirty: NSRect) {
        Theme.frame.setFill()
        CGRect(x: Self.grabMargin, y: 0, width: Self.lineWidth, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        grabOffset = convert(event.locationInWindow, from: nil).x - Self.grabMargin
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - grabOffset)
    }
}

extension Notification.Name {
    static let splitResized = Notification.Name("PorpoiseSplitResized")
}
