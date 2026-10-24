import AppKit
import PorpoiseServices

/// Tool output lives inside Activity, separate from persistent file-operation history.
final class CustomToolActivityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let output = NSTextView()
    let status = NSTextField(labelWithString: "No custom tools have run.")
    private let cancel = NSButton(title: "Cancel Tool", target: nil, action: nil)
    private var runs: [CustomToolRun] = []
    private var observer: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("tool")); table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 28; table.setAccessibilityLabel("Custom tool runs")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.heightAnchor.constraint(equalToConstant: 116).isActive = true
        output.isEditable = false; output.isSelectable = true; output.isRichText = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); output.setAccessibilityLabel("Custom tool output")
        output.autoresizingMask = [.width]; output.isVerticallyResizable = true; output.isHorizontallyResizable = false
        output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        cancel.target = self; cancel.action = #selector(cancelRun)
        let clear = ClosureButton(title: "Clear Finished") { _ in CustomToolRunner.shared.clearFinished() }
        let controls = NSStackView(views: [cancel, clear, status]); controls.spacing = 10
        let stack = NSStackView(views: [list, scroll, controls]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        observer = NotificationCenter.default.addObserver(forName: CustomToolRunner.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        Theme.whenChanged(self) { [weak self] in
            self?.table.backgroundColor = Theme.viewBackground; self?.output.backgroundColor = Theme.viewBackground
            self?.output.textColor = Theme.viewText; self?.status.textColor = Theme.viewTextInactive
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected: CustomToolRun? { runs[safe: table.selectedRow] }
    private func reload() {
        let selectedID = selected?.id
        runs = CustomToolRunner.shared.runs; table.reloadData()
        if !runs.isEmpty {
            let index = runs.firstIndex { $0.id == selectedID } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        update()
    }
    private func update() {
        let run = selected
        output.string = run?.output ?? ""
        status.stringValue = run?.status ?? "No custom tools have run."
        cancel.isEnabled = run?.isRunning == true
        setAccessibilityLabel(run.map { $0.name + ". " + $0.status } ?? "Custom tool activity")
    }
    @objc private func cancelRun() { selected?.cancel() }
    func tableViewSelectionDidChange(_ notification: Notification) { update() }
    func numberOfRows(in tableView: NSTableView) -> Int { runs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let run = runs[row]; let label = NSTextField(labelWithString: run.name + " · " + run.status)
        label.lineBreakMode = .byTruncatingTail; return label
    }
}
