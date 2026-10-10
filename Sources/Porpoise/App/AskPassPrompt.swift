import AppKit
import PorpoiseServices

extension AskPass {
    /// Runs in the helper process: shows a dialog, prints the answer, exits.
    static func runHelper(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let a = NSAlert()
        let isConfirm = prompt.lowercased().contains("yes/no") || prompt.lowercased().contains("continue connecting")
        a.messageText = isConfirm ? "Connect to this server?" : "Authentication Required"
        a.informativeText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        a.addButton(withTitle: isConfirm ? "Connect" : "OK")
        a.addButton(withTitle: "Cancel")
        var field: NSSecureTextField?
        if !isConfirm {
            let f = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
            a.accessoryView = f
            a.window.initialFirstResponder = f
            field = f
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { exit(1) }
        print(isConfirm ? "yes" : (field?.stringValue ?? ""))
        exit(0)
    }
}
