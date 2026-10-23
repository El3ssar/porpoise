import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    var customToolContext: CustomToolContext {
        CustomToolContext(folder: view.url, otherFolder: tab.inactive?.url, items: view.model.selectedItems)
    }
    func customToolMenu(_ placement: CustomTool.Placement) -> NSMenu {
        let menu = NSMenu(title: "Custom Tools")
        let tools = Settings.shared.customTools.filter { $0.placements.contains(placement) }
        guard !tools.isEmpty else { return menu }
        let context = customToolContext
        for tool in tools {
            let item = NSMenuItem(title: tool.name, action: #selector(runCustomTool(_:)), keyEquivalent: "")
            item.representedObject = tool.id.uuidString; item.target = self
            let reason = tool.unavailableReason(in: context)
            item.isEnabled = reason == nil
            item.toolTip = reason
            menu.addItem(item)
        }
        menu.autoenablesItems = true
        return menu
    }
    @objc func runCustomTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
            let tool = Settings.shared.customTools.first(where: { $0.id == id })
        else { return }
        executeCustomTool(tool)
    }
    func executeCustomTool(_ tool: CustomTool) {
        // Capture originating pane, folder and selection before any sheet changes the responder.
        let context = customToolContext
        guard tool.unavailableReason(in: context) == nil else { return }
        let run: (String?) -> Void = { [weak self] value in
            do {
                try CustomToolRunner.shared.start(id: tool.id, context: context, value: value, confirmedLargeSelection: true)
                ActivityWindowController.shared.showTools()
            } catch { self?.reportError(error.localizedDescription) }
        }
        let prompt = { [weak self] in
            guard !tool.prompt.isEmpty else { run(nil); return }
            let alert = NSAlert(); alert.messageText = tool.name; alert.informativeText = tool.prompt
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 24))
            field.setAccessibilityLabel(tool.prompt); alert.accessoryView = field
            alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.runSheet(for: self?.window) { response in if response == .alertFirstButtonReturn { run(field.stringValue) } }
        }
        guard context.needsConfirmation else { prompt(); return }
        let alert = NSAlert(); alert.messageText = "Run “\(tool.name)” on \(context.items.count) items?"
        alert.informativeText = "The command will receive every selected path. Changes made by custom tools cannot be undone by Porpoise."
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.runSheet(for: window) { response in if response == .alertFirstButtonReturn { prompt() } }
    }
    @objc func showCustomTools(_ sender: Any?) { SettingsWindowController(page: "Custom Tools").present() }
    @objc func showToolbarCustomTools(_ sender: Any?) {
        let menu = customToolMenu(.toolbar)
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "Configure Custom Tools…", action: #selector(showCustomTools(_:)), keyEquivalent: ""))
        }
        if let button = sender as? NSView { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
    }
}
