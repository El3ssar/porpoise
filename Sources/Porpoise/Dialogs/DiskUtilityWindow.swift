import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// The type scale, shortened for the many text styles in this file.
private typealias FontSize = Tokens.FontSize

/// Common native table/progress shell. Every window owns and cancels its background task.
class DiskUtilityWindow: SecondaryWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let stack = NSStackView()
    let toolbar = NSStackView()
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let cancelButton = ClosureButton(title: "Cancel") { _ in }
    /// The progress bar and Cancel: on screen only while work runs (DESIGN-CONTRACT E2).
    private(set) var progressRow = NSStackView()
    /// What the table says when it has no rows and nothing runs, centred over it; nil shows nothing.
    var emptyListState: ListState? { didSet { updateEmptyState() } }
    let emptyState = ListStateView()
    var cancellation = DiskCancellation()
    var rows: [[String]] = []
    /// Shown only when a scan had errors: a disabled "No Errors" button read as a status that something had gone wrong.
    let errorsButton = ClosureButton(title: "") { _ in }
    var errors: [String] = [] {
        didSet { errorsButton.isHidden = errors.isEmpty; errorsButton.title = "Errors (\(errors.count))…" }
    }
    var busy = false
    let keys: [String]

    init(title: String, columns: [(String, String, CGFloat)], sortable: Bool = false) {
        keys = columns.map { $0.0 }
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.title = title
        super.init(window: w); w.delegate = self
        let margin = Tokens.Space.xl
        contentStack(stack, insets: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin), spacing: Tokens.Space.m)
        toolbar.orientation = .horizontal; toolbar.spacing = Tokens.Space.s
        stack.addArrangedSubview(toolbar)
        progress.style = .bar; progress.isIndeterminate = true
        progressRow = NSStackView(views: [progress, cancelButton]); progressRow.spacing = Tokens.Space.s
        progressRow.isHidden = true
        stack.addArrangedSubview(progressRow)
        progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancelButton.handler = { [weak self] _ in
            self?.cancellation.cancel(); self?.status.stringValue = "Cancelling…"
        }
        for (key, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); c.title = title; c.width = width; c.minWidth = 50
            if sortable { c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.rowHeight = 25
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true;
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        // Over the list, not in it: a scroll view lays out only its own parts.
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(emptyState, positioned: .above, relativeTo: scroll)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        emptyState.show(nil)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        // One footer line, secondary (UI-10).
        status.isSelectable = true; status.maximumNumberOfLines = 4; status.font = Tokens.font(.callout)
        status.textColor = Theme.windowTextInactive
        errorsButton.handler = { [weak self] _ in self?.showErrors() }; errorsButton.isHidden = true
        let footer = NSStackView(views: [status, errorsButton]); footer.alignment = .firstBaseline; footer.spacing = Tokens.Space.s
        stack.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        w.minSize = NSSize(width: 860, height: 500); w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { cancellation.cancel() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let key = column?.identifier.rawValue, let index = keys.firstIndex(of: key),
            rows[row].indices.contains(index)
        else { return nil }
        let label = NSTextField(labelWithString: rows[row][index]); label.lineBreakMode = .byTruncatingMiddle
        label.font =
            key == "digest"
            ? .monospacedSystemFont(ofSize: FontSize.small, weight: .regular) : .systemFont(ofSize: FontSize.callout)
        label.toolTip = rows[row][index]; label.isSelectable = true
        return label
    }
    /// Shows `emptyListState` while the table has no rows and nothing runs.
    func updateEmptyState() { emptyState.show(rows.isEmpty && !busy ? emptyListState : nil) }

    /// Work started or ended: the progress row shows only meanwhile.
    private func setBusy(_ on: Bool) {
        busy = on
        progressRow.isHidden = !on
        if on { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        cancelButton.isEnabled = on
        updateEmptyState()
        workChanged()
    }

    /// Called when work starts or ends (a toolbar to re-validate).
    func workChanged() {}

    func showErrors() {
        let alert = NSAlert(); alert.messageText = errors.isEmpty ? "No scan errors" : "\(errors.count) scan errors"
        alert.informativeText = errors.prefix(20).joined(separator: "\n"); alert.runSheet(for: window) { _ in }
    }
    func perform<T>(_ work: @escaping (DiskCancellation, @escaping (DiskProgress) -> Void) throws -> T, done: @escaping (T) -> Void) {
        cancellation.cancel(); let token = DiskCancellation(); cancellation = token
        setBusy(true); status.stringValue = "Working…"
        let throttle = NSLock(); var last = Date.distantPast
        let report: (DiskProgress) -> Void = { [weak self] update in
            guard
                throttle.withLock({
                    if Date().timeIntervalSince(last) < 0.1 { return false }; last = Date(); return true
                })
            else { return }
            DispatchQueue.main.async {
                guard let self, self.cancellation === token, !token.isCancelled else { return }
                self.status.stringValue = "\(update.files.formatted()) items · \(FileFormat.size(update.bytes)) processed · \(update.path)"
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let result = try work(token, report)
                DispatchQueue.main.async {
                    guard let self, self.cancellation === token else { return }
                    self.setBusy(false)
                    if token.isCancelled { self.status.stringValue = "Cancelled"; return }
                    done(result)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.cancellation === token else { return }
                    self.setBusy(false)
                    self.status.stringValue = error is CancellationError ? "Cancelled" : error.localizedDescription
                }
            }
        }
    }
    /// A line of help above the footer; `details` (the fine print) shows as its tooltip.
    func note(_ text: String, details: String? = nil) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = Theme.windowTextInactive; label.font = .systemFont(ofSize: FontSize.callout)
        label.toolTip = details
        stack.insertArrangedSubview(label, at: stack.arrangedSubviews.count - 1);
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}
