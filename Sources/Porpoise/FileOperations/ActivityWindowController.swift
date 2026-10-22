import AppKit
import PorpoiseCore
import PorpoiseServices

/// Window › Activity (⌥⌘J): every file operation of this session (queued, running, paused, ended) with pause,
/// cancel, reorder and retry, and the history of earlier ones, searchable and exportable.
final class ActivityWindowController: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
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
        menu.addItem(.separator())
        let rules = NSMenuItem(title: "Transfer Rules…", action: #selector(showTransferRules), keyEquivalent: "")
        rules.target = self
        menu.addItem(rules)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
    }

    @objc private func changeConcurrency(_ sender: NSMenuItem) { controller.concurrency = sender.tag }
    @objc private func toggleVerification() { Settings.shared.verifyCopies.toggle() }
    @objc private func showTransferRules() { SettingsWindowController(page: "Activity").present() }

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
                edits.isEmpty ? nil : edits.count == 1 ? "1 file being edited" : "\(FileFormat.count(edits.count)) files being edited",
                active > 0 ? "\(FileFormat.count(active)) running" : nil,
                paused > 0 ? "\(FileFormat.count(paused)) paused" : nil,
                queued > 0 ? "\(FileFormat.count(queued)) queued" : nil,
                finished > 0 ? "\(FileFormat.count(finished)) finished" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        if !historyPane.isHidden {
            history = controller.history.entries(matching: search.stringValue)
            historyTable.reloadData()
            footer.text = "\(FileFormat.count(history.count)) operations in history"
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
            let what = e.items == 1 ? (e.sources.first.map(Self.name) ?? "1 item") : FileFormat.itemCount(e.items)
            text = what + (e.destination.map { " → " + Self.name($0) } ?? "")
        default: text = e.outcome + (e.transferNotes?.last.map { " · " + $0 } ?? "")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip =
            ([e.sources.joined(separator: "\n")] + (e.destination.map { ["→ " + $0] } ?? []) + e.errors + (e.verification.map { [$0] } ?? [])
            + (e.transferNotes ?? []))
            .joined(separator: "\n")
        if tableColumn?.identifier.rawValue == "outcome", e.outcome != "Completed" { label.textColor = Theme.negativeText }
        return label
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === historyTable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = ActivityRowStyle.background(alternate: row % 2 != 0)
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
        a.buttons[0].hasDestructiveAction = true
        a.beginSheetModal(for: window) { [weak self] r in if r == .alertFirstButtonReturn { self?.controller.history.clear() } }
    }
}
