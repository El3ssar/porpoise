import AppKit
import PorpoiseCore
import PorpoiseServices

/// Save Workspace: names this window's layout. Picking or typing a saved name says that workspace will be replaced.
final class WorkspaceSaveSheet: NSObject, NSComboBoxDelegate {
    private let alert = NSAlert()
    let field = NSComboBox()
    private let note = NSTextField(labelWithString: "")
    private let layout: WindowLayout
    private(set) static var active: WorkspaceSaveSheet?

    init(layout: WindowLayout) {
        self.layout = layout
        super.init()
    }

    static func run(on window: NSWindow?, layout: WindowLayout) {
        let s = WorkspaceSaveSheet(layout: layout)
        active = s
        s.build()
        s.alert.runSheet(for: window) { [s] r in s.finish(r == .alertFirstButtonReturn) }
    }

    /// Lays out the sheet: the name field (with the saved names), and what saving under that name does.
    func build() {
        let tabs = layout.tabs.count
        alert.messageText = "Save Workspace"
        alert.informativeText =
            "Saves this window’s \(tabs == 1 ? "tab" : "\(tabs) tabs"), split views, panels, filters and view settings under a name. "
            + "Open it again from Window › Workspaces or the Command Palette."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
        field.frame = CGRect(x: 0, y: 24, width: 300, height: 26)
        field.placeholderString = "Workspace name"
        field.completes = true
        field.delegate = self
        field.setAccessibilityLabel("Workspace name")
        field.addItems(withObjectValues: Settings.shared.workspaces.map(\.name))
        note.frame = CGRect(x: 0, y: 2, width: 300, height: 18)
        note.font = Theme.smallFont
        note.textColor = NSColor.secondaryLabelColor
        v.addSubview(field)
        v.addSubview(note)
        alert.accessoryView = v
        alert.window.initialFirstResponder = field
        validate()
    }

    /// What Save would do: its title and whether it can, and the note under the name.
    var status: (button: String, enabled: Bool, note: String) {
        (alert.buttons.first?.title ?? "", alert.buttons.first?.isEnabled ?? false, note.stringValue)
    }

    func finish(_ save: Bool) {
        if Self.active === self { Self.active = nil }
        if save { Settings.shared.saveWorkspace(named: field.stringValue, layout: layout) }
    }

    /// Ends the sheet as Save would (the debug bridge).
    func pressSave() {
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn) } else { finish(true) }
    }

    func validate() {
        let name = Workspace.cleanName(field.stringValue)
        alert.buttons.first?.isEnabled = name != nil
        if let name, let existing = Workspace.named(name, in: Settings.shared.workspaces) {
            note.stringValue = "Replaces the saved workspace “\(existing.name)”."
            alert.buttons.first?.title = "Replace"
        } else {
            note.stringValue = ""
            alert.buttons.first?.title = "Save"
        }
    }

    func controlTextDidChange(_ obj: Notification) { validate() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [self] in validate() }
    }
}
