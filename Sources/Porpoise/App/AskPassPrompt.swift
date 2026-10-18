import AppKit
import PorpoiseCore
import PorpoiseServices

extension AskPass {
    /// Runs in the helper process: shows a dialog, prints the answer, exits.
    static func runHelper(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = Theme.appearance
        let lower = prompt.lowercased()
        // ssh asks again ("Please type 'yes', 'no' or the fingerprint") after an answer it didn't take.
        let isRetry = lower.contains("please type")
        // The user accepted a changed key after seeing its fingerprint: that fingerprint is the answer, and ssh takes it
        // only for a key that has it. Asked again, the key wasn't that one: no.
        if let accepted = ProcessInfo.processInfo.environment[HostKeyFingerprint.answerVariable], !accepted.isEmpty {
            print(isRetry ? "no" : accepted)
            exit(0)
        }
        let a = NSAlert()
        let isConfirm = lower.contains("yes/no") || lower.contains("continue connecting") || isRetry
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
