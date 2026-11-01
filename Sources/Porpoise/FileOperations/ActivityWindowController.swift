import AppKit
import PorpoiseCore
import PorpoiseServices

/// Compact nonmodal progress. The primary surface contains operation cards, not a per-file activity table.
/// History and custom-tool output remain available through the quiet footer navigation.
final class ActivityWindowController: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = ActivityWindowController()
    static let emptyListState = ListState(title: "No activity", message: "Copies and moves show up here.", symbol: "clock")
    let emptyState = ListStateView()
    private let controller = FileOperationsController.shared
    private let activityPane = NSView()
    private let historyPane = NSView()
    private let toolPane = CustomToolActivityView()
    private let cardScroll = NSScrollView()
    private let cards = NSStackView()
    private let cardDocument = FlippedView()
    private var cardWidthConstraints: [NSLayoutConstraint] = []
    private let navigation = NSPopUpButton()
    private let clear = NSButton(title: "Clear Finished", target: nil, action: nil)
    private let settings = NSButton()
    private let historyTable = NSTableView()
    private let search = NSSearchField()
    private var rows: [Activity] = []
    private var edits: [CloudEditEntry] = []
    private var history: [HistoryEntry] = []
    private var jobCards: [UUID: TransferProgressView] = [:]
    private var editCards: [UUID: EditActivityRowView] = [:]
    private var heightConstraints: [UUID: NSLayoutConstraint] = [:]
    private var layoutIdentity: [UUID] = []
    private var reloadPending = false
    private var observers: [NSObjectProtocol] = []
    /// Closing progress dismisses that cohort; a new job can present a fresh progress window later.
    private var dismissedJobs: Set<UUID> = []
    private var section = 0
    private var lastAutomaticHeight: CGFloat?

    static func name(_ value: String) -> String {
        if !value.hasPrefix("/"), let url = URL(string: value), url.scheme != nil { return Activity.name(url) }
        return (value as NSString).lastPathComponent
    }

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 232),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Transfers"
        window.contentMinSize = NSSize(width: 480, height: 196)
        window.contentMaxSize = NSSize(width: 640, height: 720)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        for (name, object) in [
            (FileOperationsController.activityChanged, controller as AnyObject?), (OperationHistory.changed, nil), (CloudEditing.changed, nil),
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.scheduleReload() })
        }
        reload(force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Explicit navigation and background presentation both avoid activation and key-window changes.
    func show() {
        dismissedJobs.removeAll()
        reveal()
    }

    /// Called after an operation remains active long enough to merit progress. Never steals focus or reopens a
    /// cohort the user closed, and never brings an already-visible window back over the user's work.
    func showProgress() {
        let active = Set(controller.activities.filter { $0.state.isActive || $0.state == .queued }.map(\.id))
        dismissedJobs.formIntersection(active)
        let alreadyPresented = window?.isVisible == true || window?.isMiniaturized == true
        guard Self.shouldPresentProgress(active: active, dismissed: dismissedJobs, visible: alreadyPresented) else { return }
        section = 0; navigation.selectItem(at: 0)
        reveal()
    }

    static func shouldPresentProgress(active: Set<UUID>, dismissed: Set<UUID>, visible: Bool) -> Bool {
        !visible && !active.isEmpty && !active.isSubset(of: dismissed)
    }

    private func reveal() {
        reload(force: true)
        guard let window else { return }
        if !window.isVisible { window.center(); window.orderFront(nil) }
    }

    func showAndFocus(_ activity: Activity) {
        section = 0; navigation.selectItem(at: 0)
        show()
        if let card = jobCards[activity.id] { card.scrollToVisible(card.bounds) }
    }

    func showTools() {
        section = 2; navigation.selectItem(at: 2)
        show()
    }

    func windowWillClose(_ notification: Notification) {
        dismissedJobs.formUnion(controller.activities.filter { $0.state.isActive || $0.state == .queued }.map(\.id))
    }

    private func build() {
        guard let content = window?.contentView else { return }
        cardScroll.documentView = cardDocument
        cardDocument.addSubview(cards)
        cardDocument.translatesAutoresizingMaskIntoConstraints = false
        cardScroll.drawsBackground = false
        cardScroll.hasVerticalScroller = true
        cardScroll.autohidesScrollers = true
        cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = Tokens.Space.s
        cards.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardDocument.widthAnchor.constraint(equalTo: cardScroll.contentView.widthAnchor),
            cards.leadingAnchor.constraint(equalTo: cardDocument.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: cardDocument.trailingAnchor),
            cards.topAnchor.constraint(equalTo: cardDocument.topAnchor), cards.bottomAnchor.constraint(equalTo: cardDocument.bottomAnchor),
        ])
        activityPane.addSubview(cardScroll)
        cardScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardScroll.leadingAnchor.constraint(equalTo: activityPane.leadingAnchor),
            cardScroll.trailingAnchor.constraint(equalTo: activityPane.trailingAnchor),
            cardScroll.topAnchor.constraint(equalTo: activityPane.topAnchor), cardScroll.bottomAnchor.constraint(equalTo: activityPane.bottomAnchor),
        ])
        activityPane.addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: activityPane.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: activityPane.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: activityPane.topAnchor), emptyState.bottomAnchor.constraint(equalTo: activityPane.bottomAnchor),
        ])
        buildHistory()
        let footer = NSView()
        navigation.addItems(withTitles: ["Transfers", "History", "Tools"])
        navigation.controlSize = .small
        navigation.target = self; navigation.action = #selector(navigate)
        navigation.setAccessibilityLabel("Transfer window section")
        clear.controlSize = .small; clear.bezelStyle = .inline
        clear.target = self; clear.action = #selector(clearFinished)
        settings.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Transfer options")
        settings.isBordered = false; settings.target = self; settings.action = #selector(showSettings)
        settings.toolTip = "Transfer options"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [navigation, spacer, clear, settings])
        controls.spacing = Tokens.Space.s
        controls.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 24), settings.heightAnchor.constraint(equalToConstant: 24),
        ])
        for view in [activityPane, historyPane, toolPane, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 36),
        ])
        for pane in [activityPane, historyPane, toolPane] {
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor), pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                pane.topAnchor.constraint(equalTo: content.topAnchor), pane.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ])
        }
        Theme.whenChanged(self) { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    private func buildHistory() {
        search.placeholderString = "Search operation history"; search.delegate = self
        let export = ClosureButton(title: "Export…") { [weak self] _ in self?.exportHistory() }
        let clear = ClosureButton(title: "Clear…") { [weak self] _ in self?.clearHistory() }
        let header = NSStackView(views: [search, export, clear]); header.spacing = Tokens.Space.s
        for (id, title, width) in [("operation", "Operation", 290.0), ("outcome", "Result", 160.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            historyTable.addTableColumn(column)
        }
        historyTable.dataSource = self; historyTable.delegate = self
        historyTable.usesAlternatingRowBackgroundColors = true
        historyTable.setAccessibilityLabel("Operation history")
        let scroll = NSScrollView(); scroll.documentView = historyTable; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true;
        scroll.autohidesScrollers = true
        let stack = NSStackView(views: [header, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Tokens.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        historyPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: historyPane.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: historyPane.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: historyPane.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: historyPane.bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func applyTheme() {
        window?.backgroundColor = Theme.windowBackground
        historyTable.backgroundColor = Theme.viewBackground
        let state = emptyState.state; emptyState.show(nil); emptyState.show(state)
    }

    @objc private func navigate() { section = navigation.indexOfSelectedItem; reload(force: true) }
    @objc private func clearFinished() { controller.clearEnded() }

    static func ordered(_ all: [Activity]) -> [Activity] {
        all.filter(\.state.isActive) + all.filter { $0.state == .queued }
            + all.filter(\.state.isEnded).sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    /// Active progress remains above cloud-edit decisions; recent ended cards never displace running jobs.
    static func progressOrder(_ jobs: [Activity], editIDs: [UUID]) -> [UUID] {
        jobs.filter { !$0.state.isEnded }.map(\.id) + editIDs + jobs.filter(\.state.isEnded).map(\.id)
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false; self?.reload()
        }
    }

    private func reload(force: Bool = false) {
        guard force || window?.isVisible == true || rows.isEmpty else { return }
        let ordered = Self.ordered(controller.activities)
        rows = ordered.filter { !$0.state.isEnded } + ordered.filter(\.state.isEnded).prefix(3)
        edits = CloudEditing.shared.entries
        activityPane.isHidden = section != 0; historyPane.isHidden = section != 1; toolPane.isHidden = section != 2
        clear.isHidden = section != 0; clear.isEnabled = rows.contains { $0.state.isEnded }
        let ids = Self.progressOrder(rows, editIDs: edits.map(\.id))
        let needsRebuild = ids != layoutIdentity
        jobCards = jobCards.filter { id, _ in rows.contains { $0.id == id } }
        editCards = editCards.filter { id, _ in edits.contains { $0.id == id } }
        for activity in rows {
            if jobCards[activity.id] == nil {
                let card = TransferProgressView(window: window)
                card.onHeightChanged = { [weak self] in self?.layoutCards() }
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
                let width = view.widthAnchor.constraint(equalTo: cards.widthAnchor, constant: -24)
                width.isActive = true; cardWidthConstraints.append(width)
                let height = view.heightAnchor.constraint(equalToConstant: 168); height.isActive = true; heightConstraints[id] = height
            }
            layoutIdentity = ids
        }
        emptyState.show(rows.isEmpty && edits.isEmpty ? Self.emptyListState : nil)
        if section == 1 { history = controller.history.entries(matching: search.stringValue); historyTable.reloadData() }
        layoutCards()
    }

    private func layoutCards() {
        for (id, card) in jobCards { heightConstraints[id]?.constant = card.preferredHeight }
        for edit in edits { heightConstraints[edit.id]?.constant = EditActivityRowView.isTall(edit.mark) ? EditActivityRowView.conflictHeight : 56 }
        guard let window else { return }
        let height: CGFloat
        if section == 0 {
            let content = heightConstraints.values.reduce(CGFloat(24)) { $0 + $1.constant } + CGFloat(max(0, layoutIdentity.count - 1)) * 8
            height = min(520, max(196, content + 36))
        } else {
            height = 420
        }
        // Progress ticks update content, not the window frame. Resize only when the card/disclosure structure changes.
        guard lastAutomaticHeight != height else { return }
        lastAutomaticHeight = height
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: max(480, min(640, window.contentLayoutRect.width)), height: height))
        var frame = window.frame; frame.origin.y = top - frame.height; window.setFrame(frame, display: window.isVisible)
    }

    func controlTextDidChange(_ notification: Notification) { reload(force: true) }
    func numberOfRows(in tableView: NSTableView) -> Int { history.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard history.indices.contains(row) else { return nil }
        let entry = history[row]
        let source = entry.items == 1 ? entry.sources.first.map(Self.name) ?? "1 item" : FileFormat.itemCount(entry.items)
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "operation" ? entry.operation + " · " + source : entry.outcome)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip =
            ([entry.date.formatted(), entry.sources.joined(separator: "\n")] + (entry.destination.map { ["→ " + $0] } ?? []) + entry.errors
            + (entry.verification.map { [$0] } ?? []) + (entry.transferNotes ?? [])).joined(separator: "\n")
        if tableColumn?.identifier.rawValue == "outcome", entry.outcome != "Completed" { label.textColor = Theme.negativeText }
        return label
    }

    @objc private func showSettings() {
        let menu = NSMenu(title: "Transfer options")
        for count in 1...8 {
            let item = NSMenuItem(title: "Run \(count) at a time", action: #selector(changeConcurrency(_:)), keyEquivalent: "")
            item.target = self; item.tag = count; item.state = controller.concurrency == count ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let verify = NSMenuItem(title: "Verify Copies", action: #selector(toggleVerification), keyEquivalent: "")
        verify.target = self; verify.state = Settings.shared.verifyCopies ? .on : .off; menu.addItem(verify)
        let rules = NSMenuItem(title: "Transfer Rules…", action: #selector(showTransferRules), keyEquivalent: "")
        rules.target = self; menu.addItem(rules)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
    }
    @objc private func changeConcurrency(_ item: NSMenuItem) { controller.concurrency = item.tag }
    @objc private func toggleVerification() { Settings.shared.verifyCopies.toggle() }
    @objc private func showTransferRules() { AppDelegate.shared.showSettings(page: "Files", section: "Transfer rules") }

    private func exportHistory() {
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Porpoise history.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        let entries = controller.history.entries(matching: search.stringValue)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try OperationHistory.csv(entries).write(to: url, atomically: true, encoding: .utf8) } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
    private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Clear the history of file operations?"
        alert.informativeText = "Only the history is removed; your files are not affected."
        alert.addButton(withTitle: "Clear"); alert.addButton(withTitle: "Cancel"); alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.controller.history.clear() } }
    }
}
