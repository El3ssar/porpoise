import AppKit
import PorpoiseCore
import PorpoiseServices

extension AskPass {
    /// Runs in the helper process: shows a dialog, prints the answer, exits.
    static func runHelper(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = Theme.appearance
        // The user accepted a changed key after seeing its fingerprint: that fingerprint is the answer, and ssh takes it
        // only for a key that has it. Asked again, the key wasn't that one: no.
        if let answer = AskPass.acceptedAnswer(prompt: prompt, fingerprint: ProcessInfo.processInfo.environment[HostKeyFingerprint.answerVariable]) {
            print(answer)
            exit(0)
        }
        let a = NSAlert()
        let isConfirm = AskPass.isHostKeyConfirmation(prompt)
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
