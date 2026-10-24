import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

private final class ShortcutRecorder: NSButton {
    var recorded: ((KeyboardShortcut) -> Void)?
    private var monitor: Any?
    override init(frame: NSRect) {
        super.init(frame: frame); title = "Record Shortcut…"; bezelStyle = .rounded; target = self; action = #selector(record)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    @objc private func record() {
        if monitor != nil { stop(); return }
        title = "Press keys (Esc cancels)…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true else { self.stop(); return event }
            if event.keyCode == 53 { self.stop(); return nil }
            let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
            let shortcut = KeyboardShortcut(key: key, modifiers: ShortcutModifiers(event.modifierFlags))
            self.stop(); self.recorded?(shortcut); return nil
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; title = "Record Shortcut…" }
}

/// Settings embeds this view so filtering, conflict checks and recording do not need a second window.
final class ShortcutEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var all: [MenuCommandRegistry.Command] = []
    private var shown: [MenuCommandRegistry.Command] = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Select an action, then record a shortcut. Escape cancels recording.")
    private let recorder = ShortcutRecorder()
    private var observer: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        MenuCommandRegistry.shared.refresh();
        all = MenuCommandRegistry.shared.commands.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        search.placeholderString = "Find an action"; search.delegate = self; add(search)
        for (id, label, width) in [("action", "Action", 330.0), ("current", "Shortcut", 110.0), ("default", "Default(s)", 180.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = label; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 24; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true;
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true; add(scroll)
        recorder.recorded = { [weak self] shortcut in self?.bind(shortcut) }
        let clear = ClosureButton(title: "Clear") { [weak self] _ in self?.bind(KeyboardShortcut()) }
        let reset = ClosureButton(title: "Reset Selected") { [weak self] _ in self?.resetSelected() }
        let resetAll = ClosureButton(title: "Reset All…") { [weak self] _ in self?.resetAll() }
        let row = NSStackView(views: [recorder, clear, reset, resetAll]); row.spacing = 8; add(row)
        let importButton = ClosureButton(title: "Import Shortcuts…") { [weak self] _ in self?.importFile() }
        let exportButton = ClosureButton(title: "Export Shortcuts…") { [weak self] _ in self?.exportFile() }
        let files = NSStackView(views: [importButton, exportButton]); files.spacing = 8; add(files)
        status.font = .systemFont(ofSize: Tokens.FontSize.callout); add(status)
        shown = all; table.reloadData(); if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            // Another key set rebuilds the menu bar: list its new items and defaults.
            let defaultsChanged = note.object == nil || note.object as? String == "shortcutKeySet"
            DispatchQueue.main.async {
                if defaultsChanged { self?.reloadCommands() } else { self?.table.reloadData() }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected: MenuCommandRegistry.Command? { shown[safe: table.selectedRow] }
    private func reloadCommands() {
        all = MenuCommandRegistry.shared.commands.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    func controlTextDidChange(_ obj: Notification) {
        let candidates = all.map { CommandCandidate(id: $0.id, title: $0.path) }
        let ids = CommandSearch.rank(search.stringValue, candidates: candidates, limit: all.count).map { $0.candidate.id }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }); shown = ids.compactMap { byID[$0] }
        table.reloadData(); if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { recorder.stop() }
    private func bind(_ shortcut: KeyboardShortcut) {
        guard let selected else { status.stringValue = "Select an action first."; return }
        do {
            try shortcut.validate()
            let ownsDefault = selected.defaults.contains { $0.normalized == shortcut.normalized }
            if !shortcut.isEmpty && !ownsDefault
                && (shortcut.isReservedByAppKit || MenuCommandRegistry.shared.appKitBindings.contains { $0.normalized == shortcut.normalized })
            {
                throw ShortcutError.invalid("This shortcut belongs to macOS.")
            }
            MenuCommandRegistry.shared.refresh(fillDynamic: false)
            var preferences = Settings.shared.keyboardShortcuts; preferences.overrides[selected.id] = shortcut
            let conflicts = preferences.conflicts(actions: MenuCommandRegistry.shared.shortcutActions)
            guard conflicts.isEmpty else {
                let names = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.path) })
                status.stringValue = conflicts.map {
                    "\($0.shortcut.display): \(names[$0.first] ?? $0.first) conflicts with \(names[$0.second] ?? $0.second)"
                }.joined(separator: "\n")
                status.textColor = Theme.negativeText; return
            }
            Settings.shared.keyboardShortcuts = preferences
            status.stringValue = "\(selected.path): \(shortcut.display). Applied to the menu immediately."; status.textColor = Theme.viewTextInactive
        } catch { status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText }
    }
    private func resetSelected() {
        guard let selected else { return }
        var preferences = Settings.shared.keyboardShortcuts; preferences.overrides.removeValue(forKey: selected.id)
        let conflicts = preferences.conflicts(actions: MenuCommandRegistry.shared.shortcutActions)
        guard conflicts.isEmpty else {
            status.stringValue = "The default conflicts with another customized action. Clear that binding or Reset All first."; return
        }
        Settings.shared.keyboardShortcuts = preferences; status.stringValue = "Default shortcuts restored."; status.textColor = Theme.viewTextInactive
    }
    /// Asks first: the user's own bindings can't be brought back (unless exported).
    private func resetAll() {
        guard Settings.shared.keyboardShortcuts != ShortcutPreferences() else { return }
        let alert = NSAlert()
        alert.messageText = "Reset all keyboard shortcuts?"
        alert.informativeText = "Every shortcut you changed goes back to its default. This can't be undone; export your shortcuts first to keep them."
        alert.addButton(withTitle: "Reset All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let reset = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { Settings.shared.keyboardShortcuts = ShortcutPreferences() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: reset) } else { reset(alert.runModal()) }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Settings.shared.importKeyboardShortcuts(Data(contentsOf: url), actions: MenuCommandRegistry.shared.shortcutActions);
            status.stringValue = "Shortcuts imported."; status.textColor = Theme.viewTextInactive
        } catch { status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText }
    }
    private func exportFile() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Porpoise-shortcuts.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Settings.shared.keyboardShortcuts.encoded().write(to: url, options: .atomic); status.stringValue = "Shortcuts exported." } catch {
            status.stringValue = error.localizedDescription
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let command = shown[safe: row] else { return nil }
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "action": value = command.path
        case "current": value = MenuCommandRegistry.shared.shortcut(for: command.id).display
        default: value = command.defaults.map(\.display).joined(separator: " / ")
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = value
        return label
    }
}

enum ShortcutSettingsPage {
    static func build(_ form: FormBuilder) {
        form.section("Key set")
        form.radio(
            [
                "Mac (Finder): ⌘H hides Porpoise, ⌘I Get Info, Return renames, ⌘⌫ moves to the Trash",
                "Dolphin: ⌘H shows hidden files, ⌘I filters, F2 renames, Return opens, ⌦ moves to the Trash",
            ], ShortcutKeySet.allCases.firstIndex(of: Settings.shared.shortcutKeySet) ?? 0
        ) { Settings.shared.shortcutKeySet = ShortcutKeySet.allCases[$0] }
        form.note("Shortcuts you've changed below stay as you set them in either key set.")
        form.section("Keyboard shortcuts")
        form.note(
            "Rebind menu actions, including their hidden alternate shortcuts. Conflicting bindings are blocked. Text editing and view navigation keep their normal keys. Help › Keyboard Shortcuts (⌘?) lists them all."
        )
        let editor = ShortcutEditorView()
        form.stack.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: form.stack.widthAnchor, constant: -60).isActive = true
        form.section("Toolbar")
        form.button("Customize Toolbar…") { ToolbarCustomizationWindow.show() }
        form.button("Restore Default Toolbar") { Settings.shared.toolbarCommands = ToolbarCommand.defaults }
    }
}
