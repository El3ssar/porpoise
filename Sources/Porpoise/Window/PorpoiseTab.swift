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
    var linkedRoots: (left: URL, right: URL)?
    var linkUpdating = false
    var linkGeneration = 0
    var missingCounterpart: LinkedPanePlaceholder?
    var missingOnRight = true
    var customTitle: String?

    /// The line between the panes (tests drive it).
    let handle = SplitDividerView()
    /// The inspector host is a sibling behind the file panes. Its first child is an empty sizing space: file panes
    /// always remain direct children of the tab, preserving editors, scroll views and inline media across focus.
    private(set) var informationHost: NSSplitView?
    private(set) weak var informationPane: ViewContainer?

    func dockInformation(in host: NSSplitView?) {
        if informationHost === host, host == nil || informationPane === active { return }
        if informationHost !== host { informationHost?.removeFromSuperview() }
        informationHost = host
        informationPane = host == nil ? nil : active
        if let host {
            if host.superview !== self { addSubview(host, positioned: .below, relativeTo: primary) }
        }
        layoutPanes()
    }

    /// Called after the inspector divider moves: carve its width out of the pane's slot without moving the pane
    /// into another view hierarchy. The empty sizing space is behind it and never handles its events.
    func layoutInformationFiles() {
        guard let pane = informationPane, let host = informationHost, let space = host.arrangedSubviews.first else { return }
        let frame = convert(space.frame, from: host)
        if pane.frame != frame { pane.frame = frame }
    }

    private func placePane(_ pane: ViewContainer, in frame: CGRect) {
        if informationPane === pane, let host = informationHost {
            if host.frame != frame { host.frame = frame }
            layoutInformationFiles()
        } else if pane.frame != frame {
            pane.frame = frame
        }
    }

    /// Split flights land in the files, excluding the inspector beside the pane that will become active.
    private func filesWidth(in slot: CGFloat) -> CGFloat {
        guard let host = informationHost else { return slot }
        return max(0, slot - PanelSize.informationWidth.fitted(in: slot, divider: host.dividerThickness) - host.dividerThickness)
    }
    /// Handle position as a fraction of the width, so it stays proportional when the window resizes.
    private var splitFraction: CGFloat = 0.5
    /// Pane being closed: still visible while it shrinks away (Dolphin keeps such "zombie" views).
    private(set) var closing: ViewContainer?
    private var closingOnLeft = false
    /// The close slide ended while the copies flying back were still landing (they show their end a frame later):
    /// the closing pane goes once they have.
    private var closesWhenLanded = false
    private let animator = Animator(name: "split.pane")
    /// The split view is sliding open or closed.
    var isSliding: Bool { animator.isRunning }
    /// The second pane is sliding in from the edge or away to it: the line goes past the panes' minimum widths.
    private var slidesToEdge = false
    /// Copies of the left pane's items flying into the right one as the split opens.
    private var flightOverlay: SplitFlightOverlay?
    private let flightAnimator = Animator(name: "split.flight")
    /// The last flight, as it went (the debug bridge and tests read it): the sizes its first copy was drawn at, the
    /// size of the cell it landed on, and whether that cell showed its item when the copies went (no blank frame).
    struct FlightRecord {
        var sizes: [CGSize]
        var landing: CGSize?
        var shownWhenCopiesWent: Bool
        /// Sizes only grew or only shrank, and the last one is the cell's.
        var isSmooth: Bool {
            guard let landing, let last = sizes.last else { return false }
            let widths = sizes.map(\.width), heights = sizes.map(\.height)
            func monotonic(_ v: [CGFloat]) -> Bool {
                zip(v, v.dropFirst()).allSatisfy { $1 >= $0 - 0.01 } || zip(v, v.dropFirst()).allSatisfy { $1 <= $0 + 0.01 }
            }
            return monotonic(widths) && monotonic(heights) && abs(last.width - landing.width) < 0.5
                && abs(last.height - landing.height) < 0.5
        }
    }
    private(set) var lastFlight: FlightRecord? { didSet { flightsLanded += 1 } }
    /// How many flights have landed (a test waits for the next one).
    private(set) var flightsLanded = 0
    /// The right list's width once the split has opened: which of its items fly in (in Compact, items flow in
    /// columns, and the still narrow pane would show only the first).
    private var openingRightWidth: CGFloat?
    /// Handle position the user chose last; reopening the split returns to it (m_splitterLastPosition). Tests that move
    /// the line put it back.
    static var lastFraction: CGFloat = 0.5

    var active: ViewContainer { activeIsSecondary ? (secondary ?? primary) : primary }
    var inactive: ViewContainer? { secondary == nil ? nil : (activeIsSecondary ? primary : secondary) }
    /// Column view shows one pane: no split while it's the view.
    var canSplit: Bool { !active.showsColumns }

    /// Column view chosen in a split: the other pane closes, and `pane` (in Column view now) stays alone.
    func keepAlone(_ pane: ViewContainer) {
        guard isSplit, containers.contains(where: { $0 === pane }) else { return }
        setActive(secondary: pane === secondary)
        closeSplit(closeActive: false)
    }
    var isSplit: Bool { secondary != nil }
    var containers: [ViewContainer] { [primary] + (secondary.map { [$0] } ?? []) }

    /// `loadsWhenShown`: the panes list their folders when the tab is first shown.
    init(url: URL, loadsWhenShown: Bool = false) {
        primary = ViewContainer(url: url, loadsWhenShown: loadsWhenShown)
        super.init(frame: .zero)
        addSubview(primary)
        addSubview(handle)
        handle.onDrag = { [weak self] x in self?.dragHandle(to: x) }
        handle.onDoubleClick = { [weak self] in self?.resetSplitterSizes() }
        handle.onStep = { [weak self] right in self?.stepHandle(right: right) }
        handle.share = { [weak self] in self?.splitFraction ?? 0.5 }
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
        defer {
            if let missingCounterpart { missingCounterpart.frame = missingOnRight ? (secondary?.frame ?? bounds) : primary.frame }
            NotificationCenter.default.post(name: .splitResized, object: self)
        }
        let b = bounds
        let left: ViewContainer, right: ViewContainer
        if let s = secondary {
            (left, right) = (primary, s)
        } else if let z = closing {
            (left, right) = closingOnLeft ? (z, primary) : (primary, z)
        } else {
            placePane(primary, in: b)
            handle.isHidden = true
            return
        }
        let line = SplitDividerView.lineWidth
        // At rest (and while dragging or resizing the window) both panes keep their minimum width; the fraction stays
        // as chosen, so the line comes back where it was when the window grows again.
        let x = slidesToEdge ? (b.width * splitFraction).rounded() : SplitLayout.lineX(fraction: splitFraction, in: b.width)
        placePane(left, in: CGRect(x: 0, y: 0, width: x, height: b.height))
        placePane(right, in: CGRect(x: x + line, y: 0, width: max(0, b.width - x - line), height: b.height))
        handle.isHidden = false
        handle.frame = CGRect(x: x - SplitDividerView.grabMargin, y: 0, width: SplitDividerView.width, height: b.height)
        handle.directions = slidesToEdge ? .both : SplitLayout.directions(atX: x, in: b.width)
    }

    private func setFraction(_ f: CGFloat) {
        splitFraction = f
        layoutPanes()
    }

    /// Where the handle sits, as a share of the width (a workspace keeps it).
    var splitShare: CGFloat { splitFraction }

    /// Puts the handle at `share` of the width, without animation (applying a workspace).
    func setSplitShare(_ share: CGFloat) {
        guard share > 0, share < 1 else { return }
        setFraction(share)
    }

    // MARK: - Handle

    /// Drag on the handle; `windowX` is where the line should go, in window coordinates.
    private func dragHandle(to windowX: CGFloat) {
        guard secondary != nil, bounds.width > 0 else { return }
        // Grabbed while sliding open or back to halves: the slide ends where it is, with what it puts in place at its
        // end (the panes' lists laid out at their own widths again).
        animator.interrupt()
        let x = convert(CGPoint(x: windowX, y: 0), from: nil).x
        setFraction(SplitLayout.clamped(x, in: bounds.width) / bounds.width)
        Self.lastFraction = splitFraction
    }

    /// VoiceOver's increment or decrement: the line moves by a twentieth of the width.
    private func stepHandle(right: Bool) {
        guard secondary != nil, bounds.width > 0 else { return }
        animator.interrupt()
        let x = SplitLayout.lineX(fraction: splitFraction, in: bounds.width) + (right ? 1 : -1) * bounds.width / 20
        setFraction(SplitLayout.clamped(x, in: bounds.width) / bounds.width)
        Self.lastFraction = splitFraction
    }

    /// Double-click on the handle: back to equal halves (DolphinTabPageSplitterHandle).
    func resetSplitterSizes() {
        guard secondary != nil else { return }
        Self.lastFraction = 0.5
        animateFraction(to: 0.5, duration: Motion.splitReset, curve: Animator.easeOutCubic)
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
    func openSplit(url: URL? = nil, animated: Bool = true, loadsWhenShown: Bool = false) {
        guard secondary == nil, canSplit else { return }
        finishClosing()
        let s = ViewContainer(url: url ?? active.url, loadsWhenShown: loadsWhenShown && window == nil)
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
        let leftWidth = SplitLayout.lineX(fraction: Self.lastFraction, in: bounds.width)
        let rightWidth = bounds.width - leftWidth - SplitDividerView.lineWidth
        let flies = primary.list.transitions.animates
        if flies {
            // Only Icons rearranges with the width; Details and Compact just follow it smoothly.
            if primary.list.mode == .icons {
                let width = primary.listWidth(forPaneWidth: leftWidth)
                primary.list.transitions.change(.splitOpen, duration: Motion.splitOpen) { primary.list.layoutWidthOverride = width }
            }
            // The right pane is laid out at its coming width whatever its mode (its mode may only be known once its
            // listing is there): the flight lands on cells that stay put while the pane widens.
            s.list.layoutWidthOverride = primary.listWidth(forPaneWidth: filesWidth(in: rightWidth))
            openingRightWidth = primary.listWidth(forPaneWidth: filesWidth(in: rightWidth))
        }
        slidesToEdge = true
        setFraction(1)
        // Laid out now, at the edge: the flight below may start at once, and picks the items it brings in from what the
        // pane will show.
        s.layoutSubtreeIfNeeded()
        // The slide ends where the line rests (a window too narrow for the last position puts it within the minimums).
        animateFraction(to: leftWidth / bounds.width, duration: Motion.splitOpen, curve: Animator.easeOutCubic) { [weak self] in
            guard let self else { return }
            self.slidesToEdge = false
            self.primary.list.transitions.releaseWidth()
            if self.flightOverlay == nil { self.secondary?.list.transitions.releaseWidth() }
        }
        // The flight leaves once the right pane has its items: now if its listing was saved from before, else with the
        // first page of its listing (a slow Drive folder's included). Until then it's empty, so nothing of it is ever
        // seen arriving another way first.
        if flies {
            s.list.transitions.whenItemsArrive { [weak self, weak s] in
                guard let self, let s, s === self.secondary else { return }
                self.flyItems(into: s)
            }
        }
    }

    /// Opening: copies of the left pane's visible items fly to their places in `right`; its other items come in.
    private func flyItems(into right: ViewContainer) {
        let list = right.list
        // The right pane turned out to show columns (its folder's own setting): nothing flies into them.
        guard !right.showsColumns else {
            openingRightWidth = nil
            list.transitions.releaseWidth()
            return
        }
        guard let images = primary.list.transitions.flightPictures() else { return }
        if list.frames.count != list.model.rows.count { list.computeLayout() }
        let shown = CGRect(
            x: 0, y: 0, width: list.layoutWidthOverride ?? openingRightWidth ?? list.visibleWidth, height: list.visibleHeight)
        openingRightWidth = nil
        let keys = list.candidateIndexes(in: shown).map(list.key(ofRow:)).filter { images[$0] != nil }
        let landing = list.transitions.landingPictures(keys)
        list.transitions.flightStarts(hiding: Set(keys))
        fly(keys, images: images, landing: landing, from: primary.list, to: list, duration: Motion.flight) {
            [weak self, weak list] done in
            // The pane keeps its coming width until both the flight and its slide are over (whichever ends last
            // releases it: the slide's end does when the flight is gone by then).
            list?.transitions.flightLanded(Set(keys)) {
                done()
                if self?.animator.isRunning == false { list?.transitions.releaseWidth() }
            }
        }
    }

    /// Closing: copies of the closing pane's visible items fly back onto the same items in the pane that stays,
    /// turning into them on the way (that pane may show them at another size); what's only in the closing pane leaves
    /// with it.
    private func flyItems(backFrom closing: ItemListView, to remaining: ItemListView) {
        guard let images = closing.transitions.flightPictures() else { return }
        let keys = images.keys.filter { remaining.row(forKey: $0) != nil }
        let landing = remaining.transitions.landingPictures(Array(keys))
        closing.transitions.flightLeaves(Set(keys))
        remaining.transitions.flightArrives(Set(keys))
        fly(Array(keys), images: images, landing: landing, from: closing, to: remaining, duration: Motion.splitClose) {
            [weak self, weak remaining] done in
            if let remaining { remaining.transitions.flightLanded(Set(keys)) { done() } } else { done() }
            if self?.closesWhenLanded == true { self?.finishClosing() }
        }
    }

    /// Draws copies of the items `keys` travelling from where `source` shows them to where `target` shows them, both
    /// read at every frame (the panes and their items move meanwhile). `landed` gets a function that removes the
    /// copies, to call once whatever replaces them is shown.
    private func fly(
        _ keys: [String], images: [String: CGImage], landing: [String: CGImage], from source: ItemListView, to target: ItemListView,
        duration: TimeInterval, landed: @escaping (_ done: @escaping () -> Void) -> Void
    ) {
        endFlights()
        guard !keys.isEmpty else { return landed {} }
        let overlay = SplitFlightOverlay(frame: bounds)
        overlay.flights = keys.compactMap { k in
            guard let img = images[k], source.row(forKey: k) != nil else { return nil }
            return .init(key: k, image: img, landing: landing[k])
        }
        func place(_ list: ItemListView) -> (String) -> CGRect? {
            { [weak list, weak overlay] k in
                guard let list, let overlay, let i = list.row(forKey: k) else { return nil }
                return list.convert(list.flightRect(i), to: overlay)
            }
        }
        overlay.source = place(source)
        overlay.target = place(target)
        addSubview(overlay, positioned: .above, relativeTo: nil)
        flightOverlay = overlay
        flightAnimator.run(
            duration: duration, curve: Animator.easeInOutCubic, showsEnd: true,
            step: { [weak overlay] p in overlay?.progress = CGFloat(p) },
            completion: { [weak self, weak overlay, weak target] in
                landed {
                    if let overlay, let k = overlay.flights.first?.key, let target {
                        self?.lastFlight = FlightRecord(
                            sizes: overlay.drawnSizes, landing: overlay.target(k)?.size,
                            shownWhenCopiesWent: !target.transitionHidden.contains(k))
                    }
                    if self?.flightOverlay === overlay { self?.endFlights() }
                }
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
        missingCounterpart?.removeFromSuperview(); missingCounterpart = nil; linkedRoots = nil
        containers.forEach { $0.preservesMissingLocation = false }
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
        if primary.list.transitions.animates, !primary.showsColumns, !zombie.showsColumns {
            // Only Icons rearranges with the width; Details and Compact just follow it smoothly.
            if zombie.list.mode == .icons { zombie.list.layoutWidthOverride = zombie.list.visibleWidth }
            if primary.list.mode == .icons {
                let width = primary.listWidth(forPaneWidth: filesWidth(in: bounds.width))
                primary.list.transitions.change(.splitClose, duration: Motion.splitClose) { primary.list.layoutWidthOverride = width }
            }
            flyItems(backFrom: zombie.list, to: primary.list)
        }
        slidesToEdge = true
        animateFraction(to: closeSecondary ? 1 : 0, duration: Motion.splitClose, curve: Animator.easeInCubic) { [weak self] in
            guard let self else { return }
            if flightOverlay != nil, flightAnimator.isRunning { closesWhenLanded = true } else { finishClosing() }
        }
    }

    /// Drops the zombie pane (end of the close animation, or a new split opening before it ended).
    private func finishClosing() {
        closesWhenLanded = false
        animator.stop()
        slidesToEdge = false
        if flightOverlay != nil { (containers + [closing].compactMap { $0 }).forEach { $0.list.transitions.flightCancelled() } }
        endFlights()
        if let z = closing {
            z.removeFromSuperview()
            closing = nil
            layoutPanes()
        }
        primary.list.transitions.releaseWidth()
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
        // In split view only the active pane marks itself and keeps the zoom slider and free-space bar.
        let split = secondary != nil
        for pane in [primary, secondary].compactMap({ $0 }) {
            pane.showsActiveEdge = split && pane.isActive
            pane.statusBar.showsControls = !split || pane.isActive
        }
    }

    /// Pane x-ranges in window coordinates (for aligning toolbar navigators).
    var paneRanges: [ClosedRange<CGFloat>] {
        containers.map { c in
            let host: NSView = informationPane === c ? informationHost ?? c : c
            let r = host.convert(host.bounds, to: nil)
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
        LocationNaming.title(for: c.url)
    }

    var iconName: String {
        LocationNaming.icon(for: active.url)
    }
}

extension Notification.Name {
    static let splitResized = Notification.Name("PorpoiseSplitResized")
}
