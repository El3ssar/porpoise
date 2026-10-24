import AppKit
import PorpoiseCore
import PorpoiseServices

/// A draft is saved atomically; closing the editor never changes preferences.
private final class CustomToolDraft {
    var tool: CustomTool
    init(_ tool: CustomTool) { self.tool = tool }
}

final class CustomToolEditor: SecondaryWindowController {
    private let draft: CustomToolDraft
    private let form = FormBuilder()
    private let status = NSTextField(wrappingLabelWithString: "")
    let nameField: NSTextField
    let executableField: NSTextField
    let argumentsField: NSTextField
    private let saveTool: (CustomTool) throws -> Void
    init(tool: CustomTool, save: @escaping (CustomTool) throws -> Void) {
        let state = CustomToolDraft(tool)
        draft = state; saveTool = save
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
            field.setAccessibilityLabel(title); form.wide(field)
        }
        field("Name", nameField); field("Executable (absolute path)", executableField); field("Arguments (JSON array of strings)", argumentsField)
        argumentsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        form.note("Example: [\"-a\", \"256\", \"--\", \"{selection}\"]. Each string is one argument. No shell parsing, pipes or redirection.")
        form.note(
            "{selection}: one argument per selected path (whole argument only). {folder}: active folder. {otherFolder}: other split pane. {prompt}: value you enter. Programs that accept options may need -- before paths."
        )
        let choices = CustomTool.Selection.allCases
        form.popup(
            "Run on:", ["Current folder", "Exactly one selected item", "One or more selected items"],
            choices.firstIndex(of: state.tool.selection) ?? 2
        ) {
            [weak self] in self?.draft.tool.selection = choices[$0]
        }
        let targets = CustomTool.Targets.allCases
        form.popup("Item kind:", ["Files", "Folders", "Files and folders"], targets.firstIndex(of: state.tool.targets) ?? 2) { [weak self] in
            self?.draft.tool.targets = targets[$0]
        }
        form.text("Extensions (comma separated):", state.tool.extensions.joined(separator: ", ")) { [weak self] in
            self?.draft.tool.extensions = Self.list($0)
        }
        form.text("Type identifiers:", state.tool.types.joined(separator: ", ")) { [weak self] in self?.draft.tool.types = Self.list($0) }
        form.note("Leave both filters empty for all types. Otherwise an extension OR a conforming type matches; every selected item must match.")
        form.text("Value prompt (optional):", state.tool.prompt) { [weak self] in self?.draft.tool.prompt = $0 }
        form.section("Show in")
        for (placement, label) in [
            (CustomTool.Placement.contextMenu, "Context menu"), (.toolbar, "Toolbar tools menu"), (.commandPalette, "Command palette"),
        ] {
            form.check(label, state.tool.placements.contains(placement)) { [weak self] on in
                if on { self?.draft.tool.placements.insert(placement) } else { self?.draft.tool.placements.remove(placement) }
            }
        }
        form.section("Keyboard shortcut")
        form.note("Record a shortcut with ⌘, ⌃ or ⌥. Conflicts with other tools and menu commands are blocked.")
        let shortcut = CustomToolShortcutButton(shortcut: tool.shortcut) { [weak self] in self?.draft.tool.shortcut = $0 }
        form.stack.addArrangedSubview(shortcut)
        form.button("Clear Shortcut") { [weak self, weak shortcut] in
            self?.draft.tool.shortcut = KeyboardShortcut(); shortcut?.setShortcut(KeyboardShortcut())
        }
        form.wide(status)
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
            draft.tool.name = nameField.stringValue; draft.tool.executable = executableField.stringValue
            draft.tool.arguments = try JSONDecoder().decode([String].self, from: Data(argumentsField.stringValue.utf8))
            try draft.tool.validate(); try saveTool(draft.tool); window?.close(); return true
        } catch { status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText; return false }
    }
}

final class CustomToolShortcutButton: NSButton {
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
    /// Only while it's the focus: clicked into another field, ⌘A or ⌘V there are the field's, not a shortcut.
    var isRecording: Bool { recording }
    override func resignFirstResponder() -> Bool {
        if recording { setShortcut(current) }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording, window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { setShortcut(current); return }
        let shortcut = KeyboardShortcut(key: event.charactersIgnoringModifiers ?? "", modifiers: ShortcutModifiers(event.modifierFlags)).normalized
        do { try shortcut.validate(); changed(shortcut); setShortcut(shortcut) } catch { NSSound.beep() }
    }
}
