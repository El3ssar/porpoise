import AppKit
import PorpoiseCore
import PorpoiseServices

final class BatchRenameDialog: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let sources: [URL]
    private let done: ([URL]) -> Void
    private var snapshot: BatchRenameSnapshot?
    private var plan: BatchRenamePlan?
    private var rows: [BatchRenameRuleRow] = []
    private let rules = NSStackView()
    private let presetMenu = NSPopUpButton()
    private let presetName = NSTextField(string: "")
    private let extensionMenu = NSPopUpButton()
    private let extensionText = NSTextField(string: "")
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Reading files…")
    private let apply = NSButton(title: "Rename", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var busy = false
    private let previewQueue = DispatchQueue(label: "app.porpoise.rename-preview", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var previewWork: DispatchWorkItem?
    private var previewCancellation = DiskCancellation()
    private var previewGeneration = 0
    private var snapshotGeneration = 0
    private var finished = false

    static func run(_ sources: [URL], window: NSWindow?, done: @escaping ([URL]) -> Void) {
        let controller = BatchRenameDialog(sources, done: done)
        guard let sheet = controller.window else { return }
        if let window {
            window.beginSheet(sheet) { _ in controller.window?.orderOut(nil) }
        } else {
            controller.showWindow(nil); NSApp.runModal(for: sheet)
        }
    }

    init(_ sources: [URL], snapshot: BatchRenameSnapshot? = nil, done: @escaping ([URL]) -> Void) {
        self.sources = sources; self.done = done
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Batch Rename"; window.minSize = NSSize(width: 900, height: 640)
        super.init(window: window)
        build()
        // Its rows' text colors are the palette's at the time they are made.
        Theme.whenChanged(self) { [weak self] in self?.table.reloadData() }
        addRule(.replace(find: "", with: "", regex: false, caseSensitive: true))
        if let snapshot { self.snapshot = snapshot; updatePreview() } else { refreshSnapshot() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard window?.contentView != nil else { return }
        let stack = contentStack(insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        func add(_ view: NSView, stretch: Bool = true) {
            stack.addArrangedSubview(view)
            if stretch { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        let title = NSTextField(labelWithString: "Rename \(sources.count) items"); title.font = Theme.boldFont; add(title)
        presetMenu.target = self; presetMenu.action = #selector(loadPreset); reloadPresets()
        presetMenu.setAccessibilityLabel("Saved rename presets"); presetMenu.widthAnchor.constraint(equalToConstant: 210).isActive = true
        presetName.placeholderString = "Preset name"; presetName.setAccessibilityLabel("Preset name")
        let save = ClosureButton(title: "Save Preset") { [weak self] _ in self?.savePreset() }
        let delete = ClosureButton(title: "Delete Preset") { [weak self] _ in self?.deletePreset() }
        let presets = NSStackView(views: [presetMenu, presetName, save, delete]); presets.spacing = 8; add(presets)
        rules.orientation = .vertical; rules.alignment = .leading; rules.spacing = 6
        let document = FlippedView(); document.addSubview(rules); rules.translatesAutoresizingMaskIntoConstraints = false
        let ruleScroll = NSScrollView(); ruleScroll.hasVerticalScroller = true; ruleScroll.autohidesScrollers = true
        ruleScroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: ruleScroll.contentView.widthAnchor),
            rules.leadingAnchor.constraint(equalTo: document.leadingAnchor), rules.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rules.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rules.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            ruleScroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        add(ruleScroll)
        let addButton = ClosureButton(title: "Add Rule") { [weak self] _ in
            self?.addRule(.replace(find: "", with: "", regex: false, caseSensitive: true)); self?.updatePreview()
        }
        let refresh = ClosureButton(title: "Refresh Files") { [weak self] _ in self?.refreshSnapshot() }
        extensionMenu.addItems(withTitles: ["Keep extension", "Lowercase extension", "Change extension", "Include extension in rules"])
        extensionMenu.target = self; extensionMenu.action = #selector(extensionChanged); extensionMenu.setAccessibilityLabel("Extension handling")
        extensionText.placeholderString = "New extension"; extensionText.delegate = self; extensionText.isEnabled = false
        extensionText.setAccessibilityLabel("New extension"); extensionText.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let controls = NSStackView(views: [addButton, refresh, extensionMenu, extensionText]); controls.spacing = 8; add(controls)
        let hint = NSTextField(
            wrappingLabelWithString:
                "Rules run from top to bottom. Positions start at 0; −1 inserts at the end. Regex replacement uses $1, $2…\nTokens: {name}, {ext}, {created:yyyy-MM-dd}, {modified:yyyy-MM-dd}, {exif:yyyy-MM-dd}, {width}, {height}, {artist}, {album}, {title}. Missing metadata blocks that row."
        )
        hint.font = .systemFont(ofSize: 11); hint.textColor = Theme.viewTextInactive; add(hint)
        for (id, title, width) in [("old", "Current name", 280.0), ("new", "New name", 280.0), ("status", "Status", 320.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24; table.setAccessibilityLabel("Batch rename preview")
        let preview = NSScrollView(); preview.documentView = table; preview.hasVerticalScroller = true; preview.hasHorizontalScroller = true
        preview.borderType = .bezelBorder; preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        add(preview)
        status.font = .systemFont(ofSize: 12); add(status)
        apply.target = self; apply.action = #selector(applyRename); apply.keyEquivalent = "\r"; apply.isEnabled = false
        cancel.target = self; cancel.action = #selector(cancelRename); cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, apply]); buttons.spacing = 8; add(buttons)
    }

    private func reloadPresets() {
        presetMenu.removeAllItems(); presetMenu.addItem(withTitle: "Saved presets…")
        // Items of their own (addItems(withTitles:) merges equal titles, so a preset named "Saved presets…" would
        // shift every other one), each carrying its preset's name.
        for name in Settings.shared.batchRenamePresets.map(\.name) {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = name
            presetMenu.menu?.addItem(item)
        }
    }
    private func preset() throws -> BatchRenamePreset {
        let mode: RenameExtension
        switch extensionMenu.indexOfSelectedItem {
        case 1: mode = .lowercase
        case 2: mode = .change(extensionText.stringValue)
        case 3: mode = .includeInRules
        default: mode = .keep
        }
        return try BatchRenamePreset(name: presetName.stringValue, rules: rows.map { try $0.rule() }, extensionMode: mode)
    }
    private func addRule(_ rule: BatchRenameRule) {
        let row = BatchRenameRuleRow(
            rule: rule,
            remove: { [weak self] row in
                guard let self else { return }; self.rows.removeAll { $0 === row }; self.syncRows()
            },
            move: { [weak self] row, direction in
                guard let self, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                let target = index + direction
                guard self.rows.indices.contains(target) else { return }
                self.rows.swapAt(index, target); self.syncRows()
            })
        row.changed = { [weak self] in self?.updatePreview() }; rows.append(row); syncRows()
    }
    private func syncRows() {
        rules.arrangedSubviews.forEach {
            rules.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for row in rows { rules.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true }
        updatePreview()
    }
    private func refreshSnapshot() {
        guard !busy else { return }
        invalidatePreview()
        snapshotGeneration += 1; let version = snapshotGeneration
        snapshot = nil; plan = nil; apply.isEnabled = false; status.stringValue = "Reading files and metadata…"
        let sources = sources
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try BatchRenameService.snapshot(sources) }
            DispatchQueue.main.async {
                guard let self, !self.finished, self.snapshotGeneration == version else { return }
                switch result {
                case .success(let snapshot): self.snapshot = snapshot; self.updatePreview()
                case .failure(let error): self.status.stringValue = error.localizedDescription; self.status.textColor = Theme.negativeText
                }
            }
        }
    }
    private func invalidatePreview() {
        previewGeneration += 1; previewWork?.cancel(); previewCancellation.cancel(); previewWork = nil
    }
    private func updatePreview() {
        guard !busy, !finished else { return }
        invalidatePreview()
        plan = nil; apply.isEnabled = false
        guard let snapshot else { return }
        do {
            let preset = try preset(), version = previewGeneration
            let cancellation = DiskCancellation(); previewCancellation = cancellation
            status.stringValue = "Updating preview…"; status.textColor = Theme.viewTextInactive
            let work = DispatchWorkItem { [weak self] in
                do {
                    let plan = try BatchRenameService.preview(snapshot, preset: preset, cancellation: cancellation)
                    let errors = plan.rows.filter { $0.problem != nil }.count
                    let changes = plan.changes.count, canApply = plan.canApply
                    try cancellation.check()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.finished, self.previewGeneration == version, !cancellation.isCancelled else { return }
                        self.plan = plan
                        self.status.stringValue =
                            errors > 0
                            ? "\(errors) blocked row(s). Resolve collisions or invalid names before renaming."
                            : "\(changes) of \(plan.rows.count) items will change. The whole batch can be undone in one step."
                        self.status.textColor = errors > 0 ? Theme.negativeText : Theme.viewTextInactive
                        self.apply.isEnabled = canApply
                        self.table.reloadData()
                    }
                } catch is CancellationError {
                    // A newer input or a closed dialog owns the preview now.
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.finished, self.previewGeneration == version else { return }
                        self.status.stringValue = error.localizedDescription; self.status.textColor = Theme.negativeText
                    }
                }
            }
            previewWork = work
            previewQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
        } catch {
            status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText; table.reloadData()
        }
    }
    @objc private func extensionChanged() { extensionText.isEnabled = extensionMenu.indexOfSelectedItem == 2; updatePreview() }
    func controlTextDidChange(_ obj: Notification) { updatePreview() }
    @objc private func loadPreset() {
        guard let name = presetMenu.selectedItem?.representedObject as? String,
            let preset = Settings.shared.batchRenamePresets.first(where: { $0.name == name })
        else { return }
        presetName.stringValue = preset.name
        rows = []
        switch preset.extensionMode {
        case .keep: extensionMenu.selectItem(at: 0)
        case .lowercase: extensionMenu.selectItem(at: 1)
        case .change(let ext): extensionMenu.selectItem(at: 2); extensionText.stringValue = ext
        case .includeInRules: extensionMenu.selectItem(at: 3)
        }
        for rule in preset.rules { addRule(rule) }; syncRows(); extensionChanged()
    }
    private func savePreset() {
        do {
            let preset = try preset()
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status.stringValue = "Enter a name for the preset."; return
            }
            Settings.shared.saveBatchRenamePreset(preset); reloadPresets()
            presetMenu.select(presetMenu.itemArray.first { $0.representedObject as? String == preset.name })
            status.stringValue = "Preset saved."
        } catch { status.stringValue = error.localizedDescription }
    }
    private func deletePreset() {
        guard let name = presetMenu.selectedItem?.representedObject as? String else { return }
        Settings.shared.batchRenamePresets.removeAll { $0.name == name }; reloadPresets()
    }
    @objc private func cancelRename() { guard !busy else { return }; finish() }
    private func finish() {
        finished = true; invalidatePreview(); snapshotGeneration += 1
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { NSApp.stopModal(); window.orderOut(nil) }
    }
    @objc private func applyRename() {
        guard !busy, let plan, plan.canApply, let snapshot else { return }
        invalidatePreview()
        busy = true; apply.isEnabled = false; cancel.isEnabled = false; status.stringValue = "Renaming…"
        window?.makeFirstResponder(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try BatchRenameService.execute(plan, snapshot: snapshot) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.cancel.isEnabled = true
                switch result {
                case .success(let result):
                    self.done(FileOperationsController.shared.finishBatchRename(result, snapshot: snapshot)); self.finish()
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription; self.status.textColor = Theme.negativeText
                    self.snapshot = nil; self.plan = nil
                    FileOperationsController.notifyChanged(snapshot.entries.map(\.url))
                }
            }
        }
    }
    #if PORPOISE_TEST_HOOKS
    func testPreviewExtension(_ value: String) {
        extensionMenu.selectItem(at: 2); extensionText.stringValue = value; extensionChanged()
    }
    var testPlan: BatchRenamePlan? { plan }
    var testCanApply: Bool { apply.isEnabled }
    func testFinish() { finish() }
    #endif
    func numberOfRows(in tableView: NSTableView) -> Int { plan?.rows.count ?? sources.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = plan?.rows[safe: index]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "old": value = row?.source.lastPathComponent ?? sources[index].lastPathComponent
        case "new": value = row?.proposedName ?? "—"
        default: value = row?.problem ?? (row?.changes == true ? "Ready" : "Unchanged")
        }
        let text = NSTextField(labelWithString: value); text.lineBreakMode = .byTruncatingMiddle; text.toolTip = value
        text.textColor = row?.problem == nil ? Theme.viewText : Theme.negativeText
        return text
    }
}
