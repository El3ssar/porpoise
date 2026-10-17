import AppKit
import PorpoiseCore
import PorpoiseServices

/// Common native table/progress shell. Every window owns and cancels its background task.
class DiskUtilityWindow: SecondaryWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let stack = NSStackView()
    let toolbar = NSStackView()
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let cancelButton = ClosureButton(title: "Cancel") { _ in }
    var cancellation = DiskCancellation()
    var rows: [[String]] = []
    private let errorsButton = ClosureButton(title: "No Errors") { _ in }
    var errors: [String] = [] {
        didSet { errorsButton.isEnabled = !errors.isEmpty; errorsButton.title = errors.isEmpty ? "No Errors" : "Errors (\(errors.count))…" }
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
        contentStack(stack)
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        stack.addArrangedSubview(toolbar)
        progress.style = .bar; progress.isIndeterminate = true
        let progressRow = NSStackView(views: [progress, cancelButton]); progressRow.spacing = 10
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
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        status.isSelectable = true; status.maximumNumberOfLines = 4; status.font = .systemFont(ofSize: 12)
        errorsButton.handler = { [weak self] _ in self?.showErrors() }; errorsButton.isEnabled = false
        let footer = NSStackView(views: [status, errorsButton]); footer.alignment = .top; footer.spacing = 10
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
        label.font = key == "digest" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        label.toolTip = rows[row][index]; label.isSelectable = true
        return label
    }
    func showErrors() {
        let alert = NSAlert(); alert.messageText = errors.isEmpty ? "No scan errors" : "\(errors.count) scan errors"
        alert.informativeText = errors.prefix(20).joined(separator: "\n"); alert.runSheet(for: window) { _ in }
    }
    func perform<T>(_ work: @escaping (DiskCancellation, @escaping (DiskProgress) -> Void) throws -> T, done: @escaping (T) -> Void) {
        cancellation.cancel(); let token = DiskCancellation(); cancellation = token
        busy = true; progress.startAnimation(nil); cancelButton.isEnabled = true; status.stringValue = "Working…"
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
                    self.progress.stopAnimation(nil); self.cancelButton.isEnabled = false; self.busy = false
                    if token.isCancelled { self.status.stringValue = "Cancelled"; return }
                    done(result)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.cancellation === token else { return }
                    self.progress.stopAnimation(nil); self.cancelButton.isEnabled = false; self.busy = false
                    self.status.stringValue = error is CancellationError ? "Cancelled" : error.localizedDescription
                }
            }
        }
    }
    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 11)
        stack.insertArrangedSubview(label, at: stack.arrangedSubviews.count - 1);
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}
