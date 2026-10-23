import AppKit
import PorpoiseCore
import PorpoiseServices

final class CustomToolsEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "Tools run only when you choose them. Importing a file never runs commands.")
    private var tools: [CustomTool] = []
    private var selectionButtons: [NSButton] = []
    private var observer: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("tool")); column.title = "Custom tools"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 28; table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Custom tools"); table.identifier = .init("customTools.list")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton { ClosureButton(title: title) { _ in action() } }
        let actions = NSStackView(views: [
            button("Add…") { [weak self] in self?.edit(nil) }, button("Edit…") { [weak self] in self?.edit(self?.selected) },
            button("Remove") { [weak self] in self?.remove() }, button("Move Up") { [weak self] in self?.move(-1) },
            button("Move Down") { [weak self] in self?.move(1) },
        ])
        selectionButtons = actions.arrangedSubviews.dropFirst().compactMap { $0 as? NSButton }
        let files = NSStackView(views: [
            button("Import…") { [weak self] in self?.importFile() }, button("Export…") { [weak self] in self?.exportFile() },
            button("Add Examples") { [weak self] in self?.save((self?.tools ?? []) + CustomToolDocument.examples) },
        ])
        let stack = NSStackView(views: [scroll, actions, files, status]); stack.orientation = .vertical; stack.alignment = .leading;
        stack.spacing = 10
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected: CustomTool? { tools[safe: table.selectedRow] }
    private func reload() { let row = table.selectedRow; tools = Settings.shared.customTools; table.reloadData(); select(row); updateButtons() }
    private func select(_ row: Int) { if tools.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
    private func save(_ next: [CustomTool]) {
        do { try Self.save(next); status.stringValue = "Tools saved." } catch { status.stringValue = error.localizedDescription }
    }
    static func save(_ tools: [CustomTool]) throws {
        // Include real menu defaults and user overrides when checking a new tool's binding.
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        let commands = MenuCommandRegistry.shared.commands.filter { $0.item.action != #selector(MainWindowController.runCustomTool(_:)) }
        for tool in tools where !tool.shortcut.isEmpty {
            if commands.contains(where: { command in
                let bindings = Settings.shared.keyboardShortcuts.overrides[command.id].map { [$0] } ?? command.defaults
                return bindings.contains { !$0.isEmpty && $0.normalized == tool.shortcut.normalized }
            }) {
                throw CustomToolError.invalid("The shortcut for “\(tool.name)” is already used by a menu command.")
            }
        }
        try Settings.shared.saveCustomTools(tools)
    }
    private func edit(_ tool: CustomTool?) {
        let original = tool ?? CustomTool(name: "New Tool", executable: "/usr/bin/true", arguments: [])
        CustomToolEditor(tool: original) { [weak self] edited in
            guard let self else { return }
            var next = self.tools
            if let index = next.firstIndex(where: { $0.id == edited.id }) { next[index] = edited } else { next.append(edited) }
            try Self.save(next)
        }.present()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        for button in selectionButtons { button.isEnabled = selected != nil }
        selectionButtons[safe: 2]?.isEnabled = table.selectedRow > 0
        selectionButtons[safe: 3]?.isEnabled = table.selectedRow >= 0 && table.selectedRow < tools.count - 1
    }
    private func remove() { guard let selected else { return }; save(tools.filter { $0.id != selected.id }) }
    private func move(_ delta: Int) {
        let from = table.selectedRow, to = from + delta
        guard tools.indices.contains(from), tools.indices.contains(to) else { return }
        var next = tools; next.swapAt(from, to); save(next); select(to)
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let document = try CustomToolDocument.decode(data)
            let alert = NSAlert(); alert.messageText = "Replace custom tools with \(document.tools.count) imported tools?"
            alert.informativeText =
                "Review commands from files you trust. Existing tools will be replaced; export them first to keep them. Importing does not run a tool."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            alert.runSheet(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.save(document.tools) } }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func exportFile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Porpoise-tools.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try CustomToolDocument(tools: tools).encoded().write(to: url, options: .atomic); status.stringValue = "Tools exported." } catch {
            status.stringValue = error.localizedDescription
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tools.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tool = tools[row]
        let label = NSTextField(labelWithString: tool.name + (tool.shortcut.isEmpty ? "" : "  ·  " + tool.shortcut.display))
        label.lineBreakMode = .byTruncatingTail; return label
    }
}

enum CustomToolsSettingsPage {
    static func build(_ form: FormBuilder) {
        form.section("Custom tools")
        form.note(
            "Run your own programs on local files and folders. Tools come only from these settings. Nothing in a browsed folder can add or run a tool."
        )
        let editor = CustomToolsEditorView()
        form.stack.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: form.stack.widthAnchor, constant: -60).isActive = true
        form.note(
            "Commands run in the active pane’s folder. Output and exit status appear in Activity. Custom tool changes cannot be undone by Porpoise.")
    }
}
