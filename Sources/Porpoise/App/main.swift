import AppKit
import PorpoiseServices

#if PORPOISE_TEST_HOOKS
// The dedicated prototype bundle is isolated even when opened from Finder, before any settings or migration.
if Bundle.main.bundleIdentifier == "app.porpoise.DesktopPrototype" {
    setenv("PORPOISE_DEFAULTS_SUITE", "app.porpoise.DesktopPrototype", 1)
    setenv("PORPOISE_BRIDGE", "desktop-prototype", 1)
}
#endif

// Desktop Mode's watcher: puts the desktop settings back if this app ends without doing so (DesktopSettingsGuard).
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == DesktopSettingsGuard.sentinelArgument, let parent = pid_t(CommandLine.arguments[2]) {
    DesktopSettingsGuard.runSentinel(parent: parent, suite: CommandLine.arguments[3])
}

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
