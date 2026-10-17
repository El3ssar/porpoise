import AppKit
import PorpoiseCore
import PorpoiseServices

/// Window › Activity (⌥⌘J): every file operation of this session (queued, running, paused, ended) with pause,
/// cancel, reorder and retry, and the history of earlier ones, searchable and exportable.
final class ActivityWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// A history entry's item: a path, or a remote location (a Google Drive item's name, not its id).
    static func name(_ s: String) -> String {
        if !s.hasPrefix("/"), let u = URL(string: s), u.scheme != nil { return Activity.name(u) }
        return (s as NSString).lastPathComponent
    }

    static let shared = ActivityWindowController()

    private let controller = FileOperationsController.shared
    private let tabs = NSSegmentedControl(labels: ["Activity", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let activityTable = NSTableView()
    private let historyTable = NSTableView()
    private let activityPane = NSView()
    private let historyPane = NSView()
    private let search = NSSearchField()
    private let clear = NSButton(title: "Clear Finished", target: nil, action: nil)
    private let settings = NSButton()
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "No activity")
    private let emptyDetail = NSTextField(labelWithString: "Copies and moves show up here.")
    private let footer = ActivityFooterView()
    private var header: ActivityHeaderView?
    private var rows: [Activity] = []
    /// Cloud files edited in other apps, listed above the jobs.
    private var edits: [CloudEditEntry] = []
    private var history: [HistoryEntry] = []
    private var reloadPending = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        w.title = "Activity"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 480, height: 300)
        w.setFrameAutosaveName("Activity")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        for (name, object) in [(FileOperationsController.activityChanged, controller as AnyObject?), (OperationHistory.changed, nil)] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.scheduleReload() })
        }
        observers.append(
            NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in self?.syncSettings() })
        observers.append(
            NotificationCenter.default.addObserver(forName: CloudEditing.changed, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleReload()
            })
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .texturedRounded
        clear.target = self
        clear.action = #selector(clearFinished)
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 12)
        clear.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Clear Finished")
        clear.imagePosition = .imageLeading
        clear.toolTip = "Clear Finished"
        settings.target = self
        settings.action = #selector(showSettings)
        settings.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Activity options")
        settings.isBordered = false
        settings.setAccessibilityLabel("Activity options")
        settings.toolTip = "Activity options"
        let header = ActivityHeaderView(tabs: tabs, clear: clear, settings: settings)
        self.header = header

        activityTable.headerView = nil
        activityTable.addTableColumn(NSTableColumn(identifier: .init("job")))
        activityTable.rowHeight = 52
        activityTable.intercellSpacing = .zero
        activityTable.dataSource = self
        activityTable.delegate = self
        activityTable.style = .plain
        activityTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let activityScroll = scroll(activityTable)
        activityScroll.translatesAutoresizingMaskIntoConstraints = false
        activityPane.addSubview(activityScroll)
        NSLayoutConstraint.activate([
            activityScroll.topAnchor.constraint(equalTo: activityPane.topAnchor),
            activityScroll.bottomAnchor.constraint(equalTo: activityPane.bottomAnchor),
            activityScroll.leadingAnchor.constraint(equalTo: activityPane.leadingAnchor),
            activityScroll.trailingAnchor.constraint(equalTo: activityPane.trailingAnchor),
        ])
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 6
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyDetail.font = .systemFont(ofSize: 12)
        empty.addArrangedSubview(emptyTitle)
        empty.addArrangedSubview(emptyDetail)
        activityPane.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: activityPane.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: activityPane.centerYAnchor),
        ])

        search.placeholderString = "Search history"
        search.delegate = self
        let export = ClosureButton(title: "Export…") { [weak self] _ in self?.exportHistory() }
        let clearHistory = ClosureButton(title: "Clear History") { [weak self] _ in self?.clearHistory() }
        let historyHeader = NSStackView(views: [search, export, clearHistory])
        historyHeader.spacing = 8
        for (id, title, width) in [
            ("date", "Date", 140.0), ("operation", "Operation", 120.0), ("items", "Items", 220.0), ("outcome", "Result", 150.0),
        ] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            historyTable.addTableColumn(col)
        }
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.usesAlternatingRowBackgroundColors = true
        historyTable.style = .fullWidth
        let historyScroll = scroll(historyTable)
        stack(historyPane, [historyHeader, historyScroll], fill: historyScroll)

        for v in [header, activityPane, historyPane, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])
        for pane in [activityPane, historyPane] {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: header.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ])
        }
        historyPane.isHidden = true
        Theme.whenChanged(self) { [weak self] in self?.applyTheme() }
        applyTheme()
        syncSettings()
    }

    private func applyTheme() {
        window?.backgroundColor = Theme.windowBackground
        for table in [activityTable, historyTable] {
            table.backgroundColor = Theme.viewBackground
            table.enclosingScrollView?.backgroundColor = Theme.viewBackground
        }
        emptyTitle.textColor = Theme.viewText
        emptyDetail.textColor = Theme.viewTextInactive
        activityTable.reloadData()
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.borderType = .noBorder
        return s
    }

    private func stack(_ pane: NSView, _ views: [NSView], fill: NSView) {
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.alignment = .leading
        st.spacing = 8
        st.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: pane.topAnchor), st.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            st.leadingAnchor.constraint(equalTo: pane.leadingAnchor), st.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
        ])
        for v in views { v.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true }
        fill.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: Settings

    private func syncSettings() { scheduleReload() }

    @objc private func clearFinished() { controller.clearEnded() }

    @objc private func showSettings() {
        let menu = NSMenu(title: "Activity options")
        let heading = NSMenuItem(title: "Copies and moves", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for count in 1...8 {
            let item = NSMenuItem(title: "Run \(count) at a time", action: #selector(changeConcurrency(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = controller.concurrency == count ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let verify = NSMenuItem(title: "Verify Copies", action: #selector(toggleVerification), keyEquivalent: "")
        verify.target = self
        verify.state = Settings.shared.verifyCopies ? .on : .off
        verify.toolTip = "Compare size and SHA-256 after copying."
        menu.addItem(verify)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
    }

    @objc private func changeConcurrency(_ sender: NSMenuItem) { controller.concurrency = sender.tag }
    @objc private func toggleVerification() { Settings.shared.verifyCopies.toggle() }

    @objc private func tabChanged() {
        activityPane.isHidden = tabs.selectedSegment != 0
        historyPane.isHidden = tabs.selectedSegment != 1
        reload()
    }

    // MARK: Data

    /// Running jobs first, then the queue in its order, then the ended ones, newest first.
    static func ordered(_ all: [Activity]) -> [Activity] {
        all.filter(\.state.isActive) + all.filter { $0.state == .queued }
            + all.filter(\.state.isEnded).sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    /// Progress arrives many times a second: the list is redrawn at most a few times.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    private func reload() {
        guard window?.isVisible == true || rows.isEmpty else { return }
        let next = Self.ordered(controller.activities)
        let nextEdits = CloudEditing.shared.entries
        if next.map(\.id) == rows.map(\.id), nextEdits.map(\.id) == edits.map(\.id),
            nextEdits.map({ EditActivityRowView.isTall($0.mark) }) == edits.map({ EditActivityRowView.isTall($0.mark) })
        {
            // Same jobs: update the rows in place (buttons keep working while you click them).
            edits = nextEdits
            for (i, e) in edits.enumerated() { (activityTable.view(atColumn: 0, row: i, makeIfNecessary: false) as? EditActivityRowView)?.update(e) }
            for (i, a) in next.enumerated() {
                (activityTable.view(atColumn: 0, row: edits.count + i, makeIfNecessary: false) as? ActivityRowView)?.update(a)
            }
        } else {
            rows = next
            edits = nextEdits
            activityTable.reloadData()
        }
        empty.isHidden = !rows.isEmpty || !edits.isEmpty
        clear.isEnabled = rows.contains { $0.state.isEnded }
        clear.contentTintColor = clear.isEnabled ? Theme.windowText : Theme.windowTextInactive
        clear.attributedTitle = NSAttributedString(
            string: "Clear Finished",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: clear.isEnabled ? Theme.windowText : Theme.windowTextInactive,
            ])
        header?.showsClear = historyPane.isHidden
        let paused = rows.filter { $0.state == .paused }.count
        let active = rows.filter { $0.state.isActive && $0.state != .paused }.count
        let queued = rows.filter { $0.state == .queued }.count
        let finished = rows.filter { $0.state.isEnded }.count
        footer.text =
            rows.isEmpty && edits.isEmpty
            ? ""
            : [
                edits.isEmpty ? nil : edits.count == 1 ? "1 file being edited" : "\(edits.count) files being edited",
                active > 0 ? "\(active) running" : nil,
                paused > 0 ? "\(paused) paused" : nil,
                queued > 0 ? "\(queued) queued" : nil,
                finished > 0 ? "\(finished) finished" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        if !historyPane.isHidden {
            history = controller.history.entries(matching: search.stringValue)
            historyTable.reloadData()
            footer.text = "\(history.count) operations in history"
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === activityTable ? edits.count + rows.count : history.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === activityTable, row < edits.count else { return tableView.rowHeight }
        return EditActivityRowView.isTall(edits[row].mark) ? EditActivityRowView.conflictHeight : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === activityTable {
            if row < edits.count {
                let v = EditActivityRowView(alternate: row % 2 == 1)
                v.update(edits[row])
                return v
            }
            let v = ActivityRowView(window: window, alternate: row % 2 == 1)
            v.update(rows[row - edits.count])
            return v
        }
        let e = history[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = e.date.formatted(date: .abbreviated, time: .shortened)
        case "operation": text = e.operation
        case "items":
            let what = e.items == 1 ? (e.sources.first.map(Self.name) ?? "1 item") : "\(e.items) items"
            text = what + (e.destination.map { " → " + Self.name($0) } ?? "")
        default: text = e.outcome
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip =
            ([e.sources.joined(separator: "\n")] + (e.destination.map { ["→ " + $0] } ?? []) + e.errors + (e.verification.map { [$0] } ?? []))
            .joined(separator: "\n")
        if tableColumn?.identifier.rawValue == "outcome", e.outcome != "Completed" { label.textColor = Theme.negativeText }
        return label
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === historyTable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = row % 2 == 0 ? Theme.viewBackground : Theme.viewAlternate
        return view
    }

    // MARK: History

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Porpoise history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard let window, let entries = Optional(controller.history.entries(matching: search.stringValue)) else { return }
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            do {
                try OperationHistory.csv(entries).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func clearHistory() {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "Clear the history of file operations?"
        a.informativeText = "Only the list is removed; your files are not affected."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in if r == .alertFirstButtonReturn { self?.controller.history.clear() } }
    }
}

/// One job in the Activity list: what it does, how far it is, and what can be done to it.
final class ActivityRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let statusBadge = NSImageView()
    private let icon = NSImageView()
    private let bar = ThinProgressView()
    private let buttons = NSStackView()
    private weak var activity: Activity?
    private weak var parentWindow: NSWindow?
    private var shownButtons: [String] = []
    private var tracking: NSTrackingArea?
    private var hovered = false
    private let alternate: Bool

    override var isFlipped: Bool { true }

    init(window: NSWindow?, alternate: Bool) {
        parentWindow = window
        self.alternate = alternate
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        buttons.spacing = 8
        icon.imageScaling = .scaleProportionallyDown
        for v in [icon, title, statusBadge, status, bar, buttons] as [NSView] { addSubview(v) }
        Theme.whenChanged(self) { [weak self] in
            guard let self, let activity = self.activity else { return }
            self.update(activity)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 16, y: 10, width: 32, height: 32)
        let actionWidth = CGFloat(shownButtons.count * 24 + max(0, shownButtons.count - 1) * 8)
        buttons.frame = CGRect(x: bounds.width - 12 - actionWidth, y: 14, width: actionWidth, height: 24)
        let textWidth = max(0, buttons.frame.minX - 12 - 60)
        title.frame = CGRect(x: 60, y: 9, width: textWidth, height: 17)
        let progressWidth = min(72, max(32, textWidth * 0.24))
        bar.frame = CGRect(x: 60, y: 34, width: progressWidth, height: 4)
        statusBadge.frame = CGRect(x: 60, y: 29, width: 12, height: 12)
        let statusX: CGFloat = !statusBadge.isHidden ? 76 : bar.isHidden ? 60 : 60 + progressWidth + 8
        status.frame = CGRect(x: statusX, y: 28, width: max(0, 60 + textWidth - statusX), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        (alternate ? Theme.viewAlternate : Theme.viewBackground).setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateReveal() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateReveal() }

    private func updateReveal() {
        buttons.alphaValue = shownButtons == ["reveal"] && !hovered ? 0 : 1
    }

    func update(_ a: Activity) {
        if activity?.id != a.id {
            if let source = a.sources.first, source.isFileURL {
                icon.image = NSWorkspace.shared.icon(forFile: source.path)
            } else {
                icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "File operation")
            }
        }
        activity = a
        icon.contentTintColor = nil
        let attributed = NSMutableAttributedString(
            string: a.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.viewText])
        if let start = a.title.firstIndex(of: "“"), let end = a.title[start...].firstIndex(of: "”") {
            let range = NSRange(start...end, in: a.title)
            attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .medium), range: range)
        }
        title.attributedStringValue = attributed
        var text = a.statusText
        let failed = a.state == .failed || (a.state == .completed && (!a.errors.isEmpty || a.verification?.ok == false))
        if failed {
            text = (a.state == .failed ? "Failed: " : "") + text
        } else if a.state == .completed {
            var details = ["✓ " + a.statusText]
            if let bytes = a.progress?.doneBytes, bytes > 0 { details.append(FileFormat.size(bytes)) }
            if let date = a.finishedAt { details.append(date.formatted(date: .omitted, time: .shortened)) }
            text = details.joined(separator: " · ")
        } else if a.state == .paused {
            text = "⏸ " + text
        }
        let statusText = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: failed ? Theme.transferDanger : Theme.viewTextInactive])
        if a.state == .completed && !failed {
            statusText.addAttribute(.foregroundColor, value: Theme.transferPositive, range: NSRange(location: 0, length: 6))
        }
        status.attributedStringValue = statusText
        statusBadge.isHidden = !failed
        if failed {
            statusBadge.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failed")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, Theme.transferDanger]))
        }
        status.toolTip = ([a.statusText] + a.errors.prefix(10)).joined(separator: "\n")
        title.toolTip = a.title
        bar.isHidden = !(a.state.isActive || a.state == .queued)
        bar.alphaValue = a.state == .paused ? 0.4 : 1
        bar.fraction = a.fraction
        bar.isIndeterminate = a.fraction <= 0 && a.state.isActive || a.state == .queued
        setButtons(for: a)
        updateReveal()
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(a.title + ". " + text)
    }

    /// The buttons that fit its state, rebuilt only when that set changes.
    private func setButtons(for a: Activity) {
        var want: [String] = []
        switch a.state {
        case .queued: want = ["up", "down", "cancel"]
        case .running: want = (a.canPause ? ["pause"] : []) + ["cancel"]
        case .paused: want = ["resume", "cancel"]
        case .waiting, .verifying: want = ["cancel"]
        case .failed: want = ["show", "retry"]
        case .completed:
            want =
                (a.errors.isEmpty ? [] : ["show"]) + (a.failedSources.isEmpty ? [] : ["retry"]) + (a.destination?.isFileURL == true ? ["reveal"] : [])
        case .cancelled: want = ["resume"] + (a.destination?.isFileURL == true ? ["reveal"] : [])
        case .interrupted: want = a.destination?.isFileURL == true ? ["reveal"] : []
        }
        guard want != shownButtons else { return }
        shownButtons = want
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let c = FileOperationsController.shared
        for w in want {
            let (symbol, tip): (String, String)
            switch w {
            case "pause": (symbol, tip) = ("pause.fill", "Pause (resumes from where it stopped)")
            case "resume": (symbol, tip) = ("play.fill", "Resume")
            case "cancel": (symbol, tip) = ("stop.fill", "Stop")
            case "up": (symbol, tip) = ("arrow.up", "Start earlier")
            case "down": (symbol, tip) = ("arrow.down", "Start later")
            case "show": (symbol, tip) = ("exclamationmark.bubble", "Show failures")
            case "retry": (symbol, tip) = ("arrow.clockwise", "Try the failed items again")
            default: (symbol, tip) = ("folder", "Show the destination")
            }
            let b = ClosureButton(title: "") { [weak self] _ in
                guard let a = self?.activity else { return }
                switch w {
                case "pause": c.pause(a)
                case "resume": c.resume(a)
                case "cancel": c.cancel(a)
                case "up": c.move(a, by: -1)
                case "down": c.move(a, by: 1)
                case "show": c.ui?.showTransferErrors(a, window: self?.parentWindow)
                case "retry": c.retry(a, window: self?.parentWindow)
                default: if let d = a.destination { (NSApp.delegate as? AppDelegate)?.newWindow(at: d) }
                }
            }
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            b.contentTintColor = Theme.windowTextInactive
            b.imagePosition = .imageOnly
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttons.addArrangedSubview(b)
        }
    }
}

/// Browser-sized glass capsules and a draggable titlebar, including space for the traffic lights.
private final class ActivityHeaderView: NSView {
    var showsClear = true { didSet { clearGroup.isHidden = !showsClear; needsLayout = true } }
    private let hairline = NSView()
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.78)
    private let tabGroup = GlassGroup()
    private let clearGroup = GlassGroup()
    private let settingsGroup = GlassGroup()
    private let tabs: NSSegmentedControl
    private let clear: NSButton
    private let settings: NSButton

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(tabs: NSSegmentedControl, clear: NSButton, settings: NSButton) {
        self.tabs = tabs
        self.clear = clear
        self.settings = settings
        super.init(frame: .zero)
        addSubview(background)
        hairline.wantsLayer = true
        addSubview(hairline)
        Theme.whenChanged(self) { [weak self] in self?.needsLayout = true }
        for group in [tabGroup, clearGroup, settingsGroup] { addSubview(group) }
        tabGroup.content.addSubview(tabs)
        clearGroup.content.addSubview(clear)
        settingsGroup.content.addSubview(settings)
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        hairline.layer?.backgroundColor = Theme.hairline.cgColor
        let narrow = bounds.width < 560
        let clearWidth: CGFloat = narrow ? 34 : 122
        clear.imagePosition = narrow ? .imageOnly : .imageLeading
        settingsGroup.frame = CGRect(x: bounds.width - 46, y: 9, width: 34, height: 34)
        clearGroup.frame = CGRect(x: settingsGroup.frame.minX - 8 - clearWidth, y: 9, width: clearWidth, height: 34)
        tabGroup.frame = CGRect(x: max(88, min((bounds.width - 164) / 2, clearGroup.frame.minX - 176)), y: 9, width: 164, height: 34)
        tabs.frame = CGRect(x: 4, y: 3, width: 156, height: 28)
        clear.frame = CGRect(x: 4, y: 3, width: clearWidth - 8, height: 28)
        settings.frame = CGRect(x: 3, y: 3, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

private final class ActivityFooterView: NSView {
    private let hairline = NSView()
    var text = "" { didSet { label.stringValue = text } }
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.82)
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        addSubview(background)
        hairline.wantsLayer = true
        addSubview(hairline)
        addSubview(label)
        Theme.whenChanged(self) { [weak self] in
            self?.label.textColor = Theme.windowTextInactive
            self?.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        hairline.layer?.backgroundColor = Theme.hairline.cgColor
        label.frame = CGRect(x: 16, y: 6, width: max(0, bounds.width - 32), height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A cloud file being edited in another app: how its saves are doing, and the choices when the service’s copy changed
/// meanwhile (Keep Both, Open Both, Replace with Mine). Nothing is ever lost: both versions stay until one is chosen.
final class EditActivityRowView: NSView {
    static let conflictHeight: CGFloat = 92
    /// Rows with a choice to make: the explanation on two lines, the buttons under it.
    static func isTall(_ mark: CloudEditMark) -> Bool { mark == .conflict || mark == .needsCopy }
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let buttons = NSStackView()
    private let close = NSButton()
    private var entry: CloudEditEntry?
    private var shownButtons: [String] = []
    private var shownService = ""
    private let alternate: Bool

    override var isFlipped: Bool { true }

    init(alternate: Bool) {
        self.alternate = alternate
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        buttons.spacing = 8
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from the list")
        close.contentTintColor = Theme.windowTextInactive
        close.target = self
        close.action = #selector(dismiss)
        for v in [icon, badge, title, detail, buttons, close] as [NSView] { addSubview(v) }
        Theme.whenChanged(self) { [weak self] in
            guard let self, let entry = self.entry else { return }
            self.update(entry)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 16, y: 10, width: 32, height: 32)
        badge.frame = CGRect(x: 36, y: 28, width: 16, height: 16)
        close.frame = CGRect(x: bounds.width - 34, y: 14, width: 22, height: 22)
        let right = close.isHidden ? bounds.width - 12 : close.frame.minX - 8
        let conflict = entry.map { Self.isTall($0.mark) } ?? false
        title.frame = CGRect(x: 60, y: 9, width: max(0, right - 60), height: 17)
        detail.frame = CGRect(x: 60, y: 27, width: max(0, (conflict ? bounds.width - 12 : right) - 60), height: conflict ? 30 : 15)
        let size = buttons.fittingSize
        buttons.frame =
            conflict
            ? CGRect(x: 60, y: 58, width: size.width, height: 26)
            : CGRect(x: right - size.width, y: 13, width: size.width, height: 26)
        if !conflict, !buttons.arrangedSubviews.isEmpty {
            title.frame.size.width = max(0, buttons.frame.minX - 8 - 60)
            detail.frame.size.width = title.frame.width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        (alternate ? Theme.viewAlternate : Theme.viewBackground).setFill()
        bounds.fill()
    }

    func update(_ e: CloudEditEntry) {
        if entry?.id != e.id { icon.image = NSWorkspace.shared.icon(forFile: e.localURL.path) }
        entry = e
        let attributed = NSMutableAttributedString(
            string: e.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.viewText])
        if let start = e.title.firstIndex(of: "“"), let end = e.title[start...].firstIndex(of: "”") {
            attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .medium), range: NSRange(start...end, in: e.title))
        }
        title.attributedStringValue = attributed
        title.toolTip = e.title
        detail.stringValue = e.detail
        detail.textColor = e.mark.needsAttention ? Theme.transferDanger : e.mark == .saved ? Theme.transferPositive : Theme.viewTextInactive
        let tint: NSColor = e.mark.needsAttention ? Theme.transferDanger : e.mark == .saved ? Theme.transferPositive : Theme.activeText
        badge.image = NSImage(systemSymbolName: e.mark.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white, tint])))
        close.isHidden = !(e.mark == .editing || e.mark == .saved)
        let service = e.provider.title
        close.toolTip = "Remove from the list (changes you save later still go to \(service) while it’s open)"
        let want: [String]
        switch e.mark {
        case .conflict: want = ["keep", "open", "replace"]
        case .needsCopy: want = ["copy"]
        case .unsent: want = ["send"]
        default: want = ["show"]
        }
        if want != shownButtons || shownService != service {
            shownButtons = want
            shownService = service
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for w in want {
                let (label, tip): (String, String)
                switch w {
                case "keep": (label, tip) = ("Keep Both", "Add your version next to \(service)’s as a separate file")
                case "open": (label, tip) = ("Open Both", "Open your version and \(service)’s side by side to compare them")
                case "replace":
                    (label, tip) = ("Replace with Mine", "Make your version the current one; \(service)’s stays in the file’s version history")
                case "send": (label, tip) = ("Send Now", "Try sending your saved changes to \(service) again")
                case "copy": (label, tip) = ("Save as a Copy in \(service)", "Add your version next to the original as a separate file")
                default: (label, tip) = ("Show in Folder", "Show the file in its \(service) folder")
                }
                let b = ClosureButton(title: label) { [weak self] _ in self?.run(w) }
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.toolTip = tip
                b.setAccessibilityLabel(tip)
                buttons.addArrangedSubview(b)
            }
        }
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(e.title + ". " + e.detail)
    }

    private func run(_ action: String) {
        guard let e = entry else { return }
        let editing = CloudEditing.shared
        switch action {
        case "keep", "copy": editing.keepBoth(e.id)
        case "open": editing.openBoth(e.id)
        case "replace": editing.replaceWithMine(e.id)
        case "send": editing.save(e.id)
        default: (NSApp.delegate as? AppDelegate)?.newWindow(at: e.folder)
        }
    }

    @objc private func dismiss() {
        guard let e = entry else { return }
        CloudEditing.shared.dismiss(e.id)
    }
}
