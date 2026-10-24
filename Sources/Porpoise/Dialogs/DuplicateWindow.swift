import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

final class DuplicateWindow: DiskUtilityWindow {
    private let roots: [URL]
    private var groups: [DuplicateGroup] = []
    private var files: [(group: Int, file: DuplicateFile)] = []
    private var marked: Set<URL> = []
    private let rules = NSPopUpButton()
    private var preferredFolder: URL?
    init(roots: [URL]) {
        self.roots = roots
        super.init(
            title: "Duplicate Finder — Review",
            columns: [("marked", "Trash?", 60), ("group", "Group", 60), ("path", "File", 480), ("size", "Size", 110), ("sharing", "Storage", 200)])
        toolbar.addArrangedSubview(ClosureButton(title: "Scan Again") { [weak self] _ in self?.scan() })
        rules.addItems(withTitles: DuplicateKeepRule.allCases.map { "Keep " + $0.title.lowercased() }); toolbar.addArrangedSubview(rules)
        toolbar.addArrangedSubview(ClosureButton(title: "Choose Keep Folder…") { [weak self] _ in self?.chooseFolder() })
        toolbar.addArrangedSubview(ClosureButton(title: "Apply Keep Rule") { [weak self] _ in self?.applyRule() })
        toolbar.addArrangedSubview(ClosureButton(title: "Move Marked to Trash") { [weak self] _ in self?.trash() })
        toolbar.addArrangedSubview(ClosureButton(title: "Show in Folder") { [weak self] _ in self?.reveal() })
        note(
            "Nothing is marked automatically. A keep rule marks the other copies for review; keep at least one file in each group. Files and keepers are rehashed before the undoable Trash action. APFS clone families may already share space, so logical duplicate bytes are not promised free disk space."
        )
        scan()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func scan() {
        let roots = roots; marked = []
        perform(
            { token, report in
                let scan = PhysicalTreeScanner.scan(roots, cancellation: token, progress: report)
                try token.check(); return try DuplicateFinder.find(in: scan, cancellation: token, progress: report)
            },
            done: { [weak self] result in
                guard let self else { return }
                self.groups = result.groups; self.errors = result.errors
                self.files = result.groups.enumerated().flatMap { group, value in value.files.map { (group, $0) } }
                self.reload()
                self.status.stringValue =
                    "Groups: \(result.groups.count) · Files: \(self.files.count) · \(FileFormat.size(result.groups.reduce(0) { $0 + $1.logicalSavings })) logical duplicate bytes · \(result.hardLinksIgnored) hard links ignored · \(result.errors.count) errors"
            })
    }
    private func reload() {
        // Clone families once per group, not once per file (thousands of copies of one file).
        let clones = groups.map(\.clones)
        var position: [Int: Int] = [:]
        rows = files.map { group, file in
            let i = position[group, default: 0]
            position[group] = i + 1
            let clone = clones[group].indices.contains(i) && groups[group].files[i] == file ? clones[group][i] : groups[group].isClone(file)
            return [
                marked.contains(file.entry.url) ? "✓" : "", "\(group + 1)", file.entry.url.path, FileFormat.size(file.entry.size),
                clone ? "APFS clone family" : (file.cloneID == nil ? "Sharing unknown" : "Separate clone family"),
            ]
        }
        table.reloadData()
    }
    override func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard column?.identifier.rawValue == "marked", files.indices.contains(row) else {
            return super.tableView(tableView, viewFor: column, row: row)
        }
        let url = files[row].file.entry.url
        let check = ClosureButton(checkboxWithTitle: "") { [weak self] button in
            guard let self else { return }
            if button.state == .on { self.marked.insert(url) } else { self.marked.remove(url) }
            self.status.stringValue = "Marked for review: \(self.marked.count)"
        }
        check.state = marked.contains(url) ? .on : .off; check.isEnabled = !busy
        check.setAccessibilityLabel("Move \(url.lastPathComponent) to Trash")
        return check
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.preferredFolder = URL(fileURLWithPath: FilePath.canonical(url.path)); self.rules.selectItem(at: 3)
            self.status.stringValue = "Keep folder: \(url.path). Apply Keep Rule to mark other copies."
        }
    }
    private func applyRule() {
        guard !busy else { return }
        let rule = DuplicateKeepRule.allCases[rules.indexOfSelectedItem]
        if rule == .inFolder && preferredFolder == nil { status.stringValue = "Choose a keep folder first."; return }
        marked = rule.marked(in: groups, preferredFolder: preferredFolder)
        reload(); status.stringValue = "Marked copies: \(marked.count). Review the list before moving to Trash."
    }
    private func reveal() {
        // In a Porpoise window, never Finder.
        if files.indices.contains(table.selectedRow) { AppDelegate.shared.reveal([files[table.selectedRow].file.entry.url]) }
    }
    private func trash() {
        guard !busy, !marked.isEmpty else { return }
        let groups = groups, marked = marked
        perform(
            { token, _ in try DuplicateFinder.validate(groups, marked: marked, cancellation: token) },
            done: { [weak self] urls in
                guard let self else { return }
                FileOperationsController.shared.trash(urls, window: self.window)
                self.marked = []; self.reload()
                self.status.stringValue = "Trash requested for \(urls.count) copies. Edit → Undo restores them. Scan again to refresh."
            })
    }
}
