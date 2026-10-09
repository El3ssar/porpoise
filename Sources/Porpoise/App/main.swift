import AppKit

// ssh calls the app back as its password/confirmation prompt (SSH_ASKPASS).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--askpass" {
    AskPass.runHelper(prompt: CommandLine.arguments.dropFirst(2).joined(separator: " "))
}

Migration.run()

let app = NSApplication.shared
app.delegate = AppDelegate.shared
app.setActivationPolicy(.regular)
app.run()
