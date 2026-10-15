import AppKit
import PorpoiseCore
import PorpoiseServices

/// Window › Activity (⌥⌘J): every file operation of this session (queued, running, paused, ended) with pause,
/// cancel, reorder and retry, and the history of earlier ones, searchable and exportable.
final class ActivityWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = ActivityWindowController()

    private let controller = FileOperationsController.shared
    private let tabs = NSSegmentedControl(labels: ["Activity", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let activityTable = NSTableView()
    private let historyTable = NSTableView()
    private let activityPane = NSView()
    private let historyPane = NSView()
    private let search = NSSearchField()
    private let concurrency = NSPopUpButton()
    private let verify = NSButton(checkboxWithTitle: "Verify copies (size and SHA-256)", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "No file operations yet.")
    private var rows: [Activity] = []
    private var history: [HistoryEntry] = []
    private var reloadPending = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: true)
        w.title = "Activity"
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
        concurrency.addItems(withTitles: (1...8).map { $0 == 1 ? "1 at a time" : "\($0) at a time" })
        concurrency.target = self
        concurrency.action = #selector(concurrencyChanged)
        concurrency.toolTip = "How many copies and moves run at once; the others wait in the queue. Trashing and deleting never wait."
        verify.target = self
        verify.action = #selector(verifyChanged)
        verify.toolTip = "After copying, compare every copied file with its original."
        let clear = ClosureButton(title: "Clear Finished") { [weak self] _ in self?.controller.clearEnded() }
        let header = NSStackView(views: [NSTextField(labelWithString: "Copies and moves:"), concurrency, NSView(), clear])
        header.spacing = 8
        let activityScroll = scroll(activityTable)
        activityTable.headerView = nil
        activityTable.addTableColumn(NSTableColumn(identifier: .init("job")))
        activityTable.rowHeight = 62
        activityTable.dataSource = self
        activityTable.delegate = self
        activityTable.style = .plain
        activityTable.usesAlternatingRowBackgroundColors = false
        empty.textColor = Theme.viewTextInactive
        empty.alignment = .center
        stack(activityPane, [header, verify, activityScroll], fill: activityScroll)
        activityPane.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: activityScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: activityScroll.centerYAnchor),
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

        for v in [tabs, activityPane, historyPane] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])
        for pane in [activityPane, historyPane] {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                pane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
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
        empty.textColor = Theme.viewTextInactive
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
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

    private func syncSettings() {
        concurrency.selectItem(at: min(7, controller.concurrency - 1))
        verify.state = Settings.shared.verifyCopies ? .on : .off
    }

    @objc private func concurrencyChanged() { controller.concurrency = concurrency.indexOfSelectedItem + 1 }
    @objc private func verifyChanged() { Settings.shared.verifyCopies = verify.state == .on }

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
        if next.map(\.id) == rows.map(\.id) {
            // Same jobs: update the rows in place (buttons keep working while you click them).
            for (i, a) in next.enumerated() { (activityTable.view(atColumn: 0, row: i, makeIfNecessary: false) as? ActivityRowView)?.update(a) }
        } else {
            rows = next
            activityTable.reloadData()
        }
        empty.isHidden = !rows.isEmpty
        if !historyPane.isHidden {
            history = controller.history.entries(matching: search.stringValue)
            historyTable.reloadData()
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === activityTable ? rows.count : history.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === activityTable {
            let v = ActivityRowView(window: window)
            v.update(rows[row])
            return v
        }
        let e = history[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = e.date.formatted(date: .abbreviated, time: .shortened)
        case "operation": text = e.operation
        case "items":
            let what = e.items == 1 ? (e.sources.first.map { ($0 as NSString).lastPathComponent } ?? "1 item") : "\(e.items) items"
            text = what + (e.destination.map { " → " + ($0 as NSString).lastPathComponent } ?? "")
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
    private let bar = NSProgressIndicator()
    private let buttons = NSStackView()
    private weak var activity: Activity?
    private weak var parentWindow: NSWindow?
    private var shownButtons: [String] = []

    init(window: NSWindow?) {
        parentWindow = window
        super.init(frame: .zero)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        buttons.spacing = 2
        for v in [title, status, bar, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ a: Activity) {
        activity = a
        title.stringValue = a.title
        var text = a.statusText
        if a.state == .running, let why = a.pauseUnavailable { text += " — " + why }
        status.stringValue = text
        status.toolTip = ([a.statusText] + a.errors.prefix(10)).joined(separator: "\n")
        status.textColor =
            a.state == .failed || (a.state == .completed && (!a.errors.isEmpty || a.verification?.ok == false))
            ? Theme.negativeText : .secondaryLabelColor
        bar.isHidden = !(a.state.isActive || a.state == .queued)
        bar.isIndeterminate =
            a.state == .queued
            || (a.planProgress == nil && (a.progress?.totalBytes ?? 0) == 0 && (a.progress?.totalItems ?? 0) == 0)
        bar.doubleValue = a.fraction
        setButtons(for: a)
    }

    /// The buttons that fit its state, rebuilt only when that set changes.
    private func setButtons(for a: Activity) {
        var want: [String] = []
        switch a.state {
        case .queued: want = ["up", "down", "cancel"]
        case .running: want = (a.canPause ? ["pause"] : []) + ["cancel"]
        case .paused: want = ["resume", "cancel"]
        case .waiting, .verifying: want = ["cancel"]
        case .failed: want = ["retry"]
        case .completed: want = (a.failedSources.isEmpty ? [] : ["retry"]) + (a.destination?.isFileURL == true ? ["reveal"] : [])
        case .cancelled, .interrupted: want = a.destination?.isFileURL == true ? ["reveal"] : []
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
            case "cancel": (symbol, tip) = ("xmark.circle.fill", "Cancel")
            case "up": (symbol, tip) = ("arrow.up", "Start earlier")
            case "down": (symbol, tip) = ("arrow.down", "Start later")
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
                case "retry": c.retry(a, window: self?.parentWindow)
                default: if let d = a.destination { (NSApp.delegate as? AppDelegate)?.newWindow(at: d) }
                }
            }
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.imagePosition = .imageOnly
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.addArrangedSubview(b)
        }
    }
}
