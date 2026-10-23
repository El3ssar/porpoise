import AppKit
import PorpoiseCore
import PorpoiseServices

/// A draft is saved atomically; closing the editor never changes preferences.
final class CustomToolEditor: SecondaryWindowController {
    private var draft: CustomTool
    private let form = FormBuilder()
    private let status = NSTextField(wrappingLabelWithString: "")
    let nameField: NSTextField
    let executableField: NSTextField
    let argumentsField: NSTextField
    private let saveTool: (CustomTool) throws -> Void
    init(tool: CustomTool, save: @escaping (CustomTool) throws -> Void) {
        draft = tool; saveTool = save
        nameField = NSTextField(string: tool.name); executableField = NSTextField(string: tool.executable)
        let data = try? JSONEncoder().encode(tool.arguments)
        argumentsField = NSTextField(wrappingLabelWithString: data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        argumentsField.isEditable = true; argumentsField.isSelectable = true; argumentsField.isBordered = true; argumentsField.drawsBackground = true
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 730, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Edit Custom Tool"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let stack = contentStack(spacing: 10)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedView(); document.addSubview(form.view); scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false; form.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            form.view.topAnchor.constraint(equalTo: document.topAnchor), form.view.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            form.view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.view.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        func field(_ title: String, _ field: NSTextField) {
            form.stack.addArrangedSubview(NSTextField(labelWithString: title))
            field.setAccessibilityLabel(title); form.stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: form.stack.widthAnchor, constant: -60).isActive = true
        }
        field("Name", nameField); field("Executable (absolute path)", executableField); field("Arguments (JSON array of strings)", argumentsField)
        argumentsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        form.note("Example: [\"-a\", \"256\", \"--\", \"{selection}\"]. Each string is one argument. No shell parsing, pipes or redirection.")
        form.note(
            "{selection}: one argument per selected path (whole argument only). {folder}: active folder. {otherFolder}: other split pane. {prompt}: value you enter. Programs that accept options may need -- before paths."
        )
        let choices = CustomTool.Selection.allCases
        form.popup(
            "Run on:", ["Current folder", "Exactly one selected item", "One or more selected items"], choices.firstIndex(of: tool.selection) ?? 2
        ) {
            [weak self] in self?.draft.selection = choices[$0]
        }
        let targets = CustomTool.Targets.allCases
        form.popup("Item kind:", ["Files", "Folders", "Files and folders"], targets.firstIndex(of: tool.targets) ?? 2) { [weak self] in
            self?.draft.targets = targets[$0]
        }
        form.text("Extensions (comma separated):", tool.extensions.joined(separator: ", ")) { [weak self] in self?.draft.extensions = Self.list($0) }
        form.text("Type identifiers:", tool.types.joined(separator: ", ")) { [weak self] in self?.draft.types = Self.list($0) }
        form.note("Leave both filters empty for all types. Otherwise an extension OR a conforming type matches; every selected item must match.")
        form.text("Value prompt (optional):", tool.prompt) { [weak self] in self?.draft.prompt = $0 }
        form.section("Show in")
        for (placement, label) in [
            (CustomTool.Placement.contextMenu, "Context menu"), (.toolbar, "Toolbar tools menu"), (.commandPalette, "Command palette"),
        ] {
            form.check(label, tool.placements.contains(placement)) { [weak self] on in
                if on { self?.draft.placements.insert(placement) } else { self?.draft.placements.remove(placement) }
            }
        }
        form.section("Keyboard shortcut")
        form.note("Record a shortcut with ⌘, ⌃ or ⌥. Conflicts with other tools and menu commands are blocked.")
        let shortcut = CustomToolShortcutButton(shortcut: tool.shortcut) { [weak self] in self?.draft.shortcut = $0 }
        form.stack.addArrangedSubview(shortcut)
        form.button("Clear Shortcut") { [weak self, weak shortcut] in
            self?.draft.shortcut = KeyboardShortcut(); shortcut?.setShortcut(KeyboardShortcut())
        }
        form.stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: form.stack.widthAnchor, constant: -60).isActive = true
        let cancel = ClosureButton(title: "Cancel") { [weak self] _ in self?.window?.close() }
        let saveButton = ClosureButton(title: "Save") { [weak self] _ in self?.save() }; saveButton.keyEquivalent = "\r"
        stack.addArrangedSubview(NSStackView(views: [cancel, saveButton]))
        panel.minSize = NSSize(width: 680, height: 480)
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    @discardableResult func save() -> Bool {
        window?.makeFirstResponder(nil)
        do {
            draft.name = nameField.stringValue; draft.executable = executableField.stringValue
            draft.arguments = try JSONDecoder().decode([String].self, from: Data(argumentsField.stringValue.utf8))
            try draft.validate(); try saveTool(draft); window?.close(); return true
        } catch { status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText; return false }
    }
}

private final class CustomToolShortcutButton: NSButton {
    private var recording = false
    private var current = KeyboardShortcut()
    private let changed: (KeyboardShortcut) -> Void
    init(shortcut: KeyboardShortcut, changed: @escaping (KeyboardShortcut) -> Void) {
        self.changed = changed; super.init(frame: .zero); bezelStyle = .rounded
        setShortcut(shortcut); target = self; action = #selector(record)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setShortcut(_ shortcut: KeyboardShortcut) {
        current = shortcut; title = shortcut.isEmpty ? "Record Shortcut…" : shortcut.display; recording = false
    }
    override var acceptsFirstResponder: Bool { true }
    @objc private func record() { recording = true; title = "Press shortcut (Esc cancels)…"; window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { setShortcut(current); return }
        let shortcut = KeyboardShortcut(key: event.charactersIgnoringModifiers ?? "", modifiers: ShortcutModifiers(event.modifierFlags)).normalized
        do { try shortcut.validate(); changed(shortcut); setShortcut(shortcut) } catch { NSSound.beep() }
    }
}
