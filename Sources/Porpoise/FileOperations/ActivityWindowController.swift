import AppKit
import PorpoiseCore
import PorpoiseServices

/// A live job popup: successful and cancelled transfers disappear without leaving an activity dashboard.
/// Persistent operation history, Undo and recovery remain owned by the services layer.
final class ActivityWindowController: SecondaryWindowController, NSWindowDelegate {
    static let shared = ActivityWindowController()
    static let emptyListState = ListState(title: "No Transfers", message: "Copies and moves appear while they run.", symbol: "arrow.right.arrow.left")
    let emptyState = ListStateView()
    private let controller: FileOperationsController
    private let cloudEditing: CloudEditing
    private let cardScroll = NSScrollView()
    private let cards = NSStackView()
    private let cardDocument = FlippedView()
    private var cardWidthConstraints: [NSLayoutConstraint] = []
    private var rows: [Activity] = []
    private var edits: [CloudEditEntry] = []
    private var jobCards: [UUID: TransferProgressView] = [:]
    private var editCards: [UUID: EditActivityRowView] = [:]
    private var heightConstraints: [UUID: NSLayoutConstraint] = [:]
    private var layoutIdentity: [UUID] = []
    private var reloadPending = false
    private var observers: [NSObjectProtocol] = []
    /// Closing progress hides that cohort; a new job can present a fresh popup later.
    private var dismissedJobs: Set<UUID> = []
    private var dismissedAttention: Set<UUID> = []
    private var lastAutomaticHeight: CGFloat?

    init(controller: FileOperationsController = .shared, cloudEditing: CloudEditing = .shared, progressWindow: NSWindow? = nil) {
        self.controller = controller
        self.cloudEditing = cloudEditing
        let window =
            progressWindow
            ?? NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 480, height: 200),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Transfers"
        window.contentMinSize = NSSize(width: 440, height: 164)
        window.contentMaxSize = NSSize(width: 640, height: 720)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        for (name, object) in [
            (FileOperationsController.activityChanged, controller as AnyObject?), (CloudEditing.changed, nil),
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.scheduleReload() })
        }
        reload()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    required init?(coder: NSCoder) { fatalError() }

    /// Explicit navigation still never activates the app or makes a window key.
    func show() {
        dismissedJobs.removeAll()
        reveal()
    }

    func showProgress() {
        reload()
        let active = Set(rows.map(\.id))
        dismissedJobs.formIntersection(active)
        let alreadyPresented = window?.isVisible == true || window?.isMiniaturized == true
        guard Self.shouldPresentProgress(active: active, dismissed: dismissedJobs, visible: alreadyPresented) else { return }
        reveal()
    }

    static func shouldPresentProgress(active: Set<UUID>, dismissed: Set<UUID>, visible: Bool) -> Bool {
        !visible && !active.isEmpty && !active.isSubset(of: dismissed)
    }

    private func reveal() {
        reload()
        guard !layoutIdentity.isEmpty, let window else { return }
        if !window.isVisible { window.center(); window.orderFront(nil) }
    }

    func showAndFocus(_ activity: Activity) {
        show()
        if let card = jobCards[activity.id] { card.scrollToVisible(card.bounds) }
    }

    /// Existing custom-tool commands retain their output destination, outside the transient copy popup.
    func showTools() { CustomToolOutputWindowController.shared.show() }

    func windowWillClose(_ notification: Notification) { dismissedJobs.formUnion(rows.map(\.id)) }

    func windowDidEndSheet(_ notification: Notification) { reload() }

    private func build() {
        guard let content = window?.contentView else { return }
        cardScroll.documentView = cardDocument
        cardDocument.addSubview(cards)
        cardDocument.translatesAutoresizingMaskIntoConstraints = false
        cardScroll.drawsBackground = false
        cardScroll.hasVerticalScroller = true
        cardScroll.autohidesScrollers = true
        cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = Tokens.Space.xl
        cards.edgeInsets = Tokens.Metric.windowInsets
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardDocument.widthAnchor.constraint(equalTo: cardScroll.contentView.widthAnchor),
            cards.leadingAnchor.constraint(equalTo: cardDocument.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: cardDocument.trailingAnchor),
            cards.topAnchor.constraint(equalTo: cardDocument.topAnchor), cards.bottomAnchor.constraint(equalTo: cardDocument.bottomAnchor),
        ])
        for view in [cardScroll, emptyState] as [NSView] {
            content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        Theme.whenChanged(self) { [weak self] in self?.window?.backgroundColor = Theme.windowBackground }
        window?.backgroundColor = Theme.windowBackground
    }

    /// Only jobs that still have work or a decision belong to the popup. Do not clear service history here.
    static func keepsVisible(_ activity: Activity) -> Bool {
        !activity.state.isEnded || activity.state == .interrupted || ActivityPresentation(activity).hasFailures
    }

    static func ordered(_ all: [Activity]) -> [Activity] {
        all.filter { !$0.state.isEnded } + all.filter { $0.state.isEnded && keepsVisible($0) }
    }

    static func progressOrder(_ jobs: [Activity], editIDs: [UUID]) -> [UUID] {
        ordered(jobs).filter { !$0.state.isEnded }.map(\.id) + editIDs + ordered(jobs).filter(\.state.isEnded).map(\.id)
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false; self?.reload()
        }
    }

    /// Internal for deterministic lifecycle fixtures; rebuilding never orders a window.
    func reload() {
        rows = Self.ordered(controller.activities).filter { !dismissedAttention.contains($0.id) }
        edits = cloudEditing.entries.filter { $0.mark == .saving || $0.mark.needsAttention }
        let ids = Self.progressOrder(rows, editIDs: edits.map(\.id))
        let needsRebuild = ids != layoutIdentity
        jobCards = jobCards.filter { id, _ in rows.contains { $0.id == id } }
        editCards = editCards.filter { id, _ in edits.contains { $0.id == id } }
        for activity in rows {
            if jobCards[activity.id] == nil {
                let card = TransferProgressView(window: window)
                card.onHeightChanged = { [weak self] in self?.layoutCards() }
                card.onDismiss = { [weak self] in
                    self?.dismissedAttention.insert(activity.id)
                    self?.reload()
                }
                jobCards[activity.id] = card
            }
            jobCards[activity.id]?.update(activity)
        }
        for edit in edits {
            let card = editCards[edit.id] ?? EditActivityRowView(alternate: false)
            card.update(edit); editCards[edit.id] = card
        }
        if needsRebuild {
            NSLayoutConstraint.deactivate(Array(heightConstraints.values) + cardWidthConstraints)
            cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
            heightConstraints.removeAll(); cardWidthConstraints.removeAll()
            for id in ids {
                guard let view = (jobCards[id] as NSView?) ?? editCards[id] else { continue }
                cards.addArrangedSubview(view)
                let width = view.widthAnchor.constraint(equalTo: cards.widthAnchor, constant: -40)
                width.isActive = true; cardWidthConstraints.append(width)
                let height = view.heightAnchor.constraint(equalToConstant: 160); height.isActive = true; heightConstraints[id] = height
            }
            layoutIdentity = ids
        }
        emptyState.show(ids.isEmpty ? Self.emptyListState : nil)
        layoutCards()
        // Keep an attached error/conflict sheet alive until its own decision has completed.
        if ids.isEmpty, window?.attachedSheet == nil {
            if window?.isMiniaturized == true { window?.close() } else { window?.orderOut(nil) }
        }
    }

    private func layoutCards() {
        for (id, card) in jobCards { heightConstraints[id]?.constant = card.preferredHeight }
        for edit in edits { heightConstraints[edit.id]?.constant = EditActivityRowView.isTall(edit.mark) ? EditActivityRowView.conflictHeight : 56 }
        guard let window else { return }
        let content = heightConstraints.values.reduce(CGFloat(40)) { $0 + $1.constant } + CGFloat(max(0, layoutIdentity.count - 1)) * 20
        let height = min(520, max(164, content))
        guard lastAutomaticHeight != height else { return }
        lastAutomaticHeight = height
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: max(440, min(640, window.contentLayoutRect.width)), height: height))
        var frame = window.frame; frame.origin.y = top - frame.height; window.setFrame(frame, display: window.isVisible)
    }
}

/// Custom tool logs are a separate, explicitly opened utility; transfers never inherit its lifetime or navigation.
final class CustomToolOutputWindowController: SecondaryWindowController {
    static let shared = CustomToolOutputWindowController()
    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Custom Tool Output"
        window.contentMinSize = NSSize(width: 480, height: 280)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = CustomToolActivityView()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() {
        guard let window else { return }
        if !window.isVisible { window.center(); window.orderFront(nil) }
    }
}
