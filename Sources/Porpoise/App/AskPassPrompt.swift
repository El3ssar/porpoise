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
        // A password saved with "Remember" answers the first prompt; a second prompt means it was wrong.
        if let saved = AskPass.savedPassword(prompt: prompt, sshProcess: getppid()) {
            print(saved)
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
            if AskPass.passwordLogin(prompt) != nil {
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "Remember this password in my keychain"
                a.suppressionButton?.state = .on  // as Finder's server login
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { exit(1) }
        if let password = field?.stringValue, a.suppressionButton?.state == .on { AskPass.remember(password, prompt: prompt) }
        print(isConfirm ? "yes" : (field?.stringValue ?? ""))
        exit(0)
    }
}
