import AppKit
import PorpoiseServices

// ssh calls the app back as its password/confirmation prompt (SSH_ASKPASS).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--askpass" {
    AskPass.runHelper(prompt: CommandLine.arguments.dropFirst(2).joined(separator: " "))
}

Migration.run()

// Porpoise reopens its own windows (SessionState); they aren't restorable by AppKit. Without this, a crash soon after
// a launch made the next launch stop at AppKit's "reopen windows?" alert, before any window, the bridge included.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])

let app = NSApplication.shared
app.delegate = AppDelegate.shared
app.setActivationPolicy(.regular)
app.run()
