import AppKit
import PorpoiseCore
import PorpoiseServices

final class AppCleanupWindow: DiskUtilityWindow {
    private let applications: [URL]
    private let catalogRoots: [URL]
    private var review: CleanupReview?
    private var marked = Set<URL>()
    private var completion: (([URL]?) -> Void)?
    private let trashButton = ClosureButton(title: "Move to Trash") { _ in }

    init(applications: [URL], originals: [URL], libraries: [URL], catalogRoots: [URL], completion: @escaping ([URL]?) -> Void) {
        self.applications = applications; self.catalogRoots = catalogRoots; self.completion = completion
        super.init(
            title: "Application Cleanup",
            columns: [
                ("mark", "Trash", 50), ("path", "Related File", 340), ("size", "Size", 85), ("reason", "Why It Matches", 330),
            ])
        let names = originals.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
        let more = originals.count > 5 ? " and \(originals.count - 5) more items" : ""
        let heading = NSTextField(wrappingLabelWithString: "Move \(names)\(more) to Trash. Select any related files to include.")
        heading.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .medium); toolbar.addArrangedSubview(heading)
        toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        heading.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        heading.maximumNumberOfLines = 3
        note(
            "Related files start unchecked. Shared containers and files claimed by another installed app are kept. Everything selected goes to Trash and can be undone."
        )
        let buttons = NSStackView(views: [ClosureButton(title: "Cancel") { [weak self] _ in self?.finish(nil) }, trashButton])
        buttons.spacing = 10; stack.insertArrangedSubview(buttons, at: stack.arrangedSubviews.count - 1)
        trashButton.isEnabled = false; trashButton.handler = { [weak self] _ in self?.accept() }
        cancelButton.handler = { [weak self] _ in self?.finish(nil) }
        cancelButton.title = "Cancel Scan"; cancelButton.isHidden = true
        let installedURLs = runningAndSelected()
        perform({ [applications] token, progress in
            let catalog = AppCleanupScanner.catalog(roots: catalogRoots, including: installedURLs, cancellation: token)
            let paths = Set(applications.map { $0.standardizedFileURL.path })
            let selected = catalog.applications.filter { paths.contains($0.url.standardizedFileURL.path) }
            return AppCleanupScanner.scan(applications: selected, installed: catalog, libraries: libraries, cancellation: token, progress: progress)
        }) { [weak self] review in
            guard let self else { return }
            self.review = review; self.errors = review.errors
            self.rows = review.candidates.map { ["", $0.url.path, FileFormat.size($0.bytes), $0.reason] }
            self.table.reloadData(); self.trashButton.isEnabled = true
            self.progress.superview?.isHidden = true
            self.status.stringValue =
                "\(review.candidates.count) related files found. Select files to include, or move only the application."
                + (review.groupOwnershipComplete ? "" : " Group containers with unverifiable ownership are kept.")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard column?.identifier.rawValue == "mark", let review, review.candidates.indices.contains(row) else {
            return super.tableView(tableView, viewFor: column, row: row)
        }
        let item = review.candidates[row]
        let check = ClosureButton(checkboxWithTitle: "") { [weak self] sender in
            guard let self else { return }
            if sender.state == .on { self.marked.insert(item.url) } else { self.marked.remove(item.url) }
            self.trashButton.title = self.marked.isEmpty ? "Move to Trash" : "Move to Trash with \(self.marked.count) Related Files"
        }
        check.state = marked.contains(item.url) ? .on : .off; check.isEnabled = !busy
        check.setAccessibilityLabel("Include \(item.url.lastPathComponent)"); return check
    }
    private func accept() {
        guard let review, !busy else { return }
        let selected = review.candidates.filter { marked.contains($0.url) }
        trashButton.isEnabled = false
        progress.superview?.isHidden = false
        let installedURLs = runningAndSelected()
        perform({ [catalogRoots] token, _ in
            // A missing/changed app must not cause support data belonging to its replacement to be removed.
            for app in review.applications {
                guard AppCleanupScanner.application(app.url)?.bundleID == app.bundleID else {
                    throw FileOperationError.failed("The application changed. Close this review and try again.")
                }
            }
            if selected.isEmpty { return [URL]() }
            let current = AppCleanupScanner.catalog(roots: catalogRoots, including: installedURLs, cancellation: token)
            return try AppCleanupScanner.validate(selected, applications: review.applications, installed: current)
        }) { [weak self] urls in self?.finish(urls) }
        table.reloadData()
    }
    private func runningAndSelected() -> [URL] {
        if Settings.isTesting { return applications }
        return applications + NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).filter { $0.pathExtension.lowercased() == "app" }
    }
    private func finish(_ urls: [URL]?) {
        let done = completion; completion = nil; cancellation.cancel(); close(); done?(urls)
    }
    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        let done = completion; completion = nil; done?(nil)
    }
}
