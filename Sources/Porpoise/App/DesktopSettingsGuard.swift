import AppKit
import PorpoiseServices

/// Puts the user's desktop settings back however Porpoise ends while Desktop Mode has them changed. Quit and turning
/// Desktop Mode off restore them already. A SIGTERM (logout scripts, `kill`, launchd) restores them before the process
/// ends as it would have, off the main thread, so even a hung Porpoise still ends. A crash or Force Quit is noticed by
/// a small watcher process (this executable, started with `--desktop-sentinel`), which restores them as soon as
/// Porpoise is gone. The watcher ignores SIGTERM, so `pkill Porpoise` (which ends Porpoise, restoring) leaves it to
/// cover a later SIGKILL; it ends with Porpoise. The next launch is the last resort.
enum DesktopSettingsGuard {
    static let sentinelArgument = "--desktop-sentinel"
    @MainActor private static var started = false
    @MainActor private static var termination: DispatchSourceSignal?

    /// Only for macOS's own preferences: UI tests' stand-ins and generic test hosts need no guard.
    @MainActor static func start() {
        guard !started, DesktopPreferences.current() === DesktopPreferences.system else { return }
        started = true
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
        source.setEventHandler {
            DesktopSystemSettings.current()?.restore()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        source.resume()
        termination = source
        guard let executable = Bundle.main.executableURL else { return }
        let sentinel = Process()
        sentinel.executableURL = executable
        sentinel.arguments = [sentinelArgument, String(getpid()), TestEnvironment.defaultsSuite.value() ?? ""]
        sentinel.standardInput = FileHandle.nullDevice
        sentinel.standardOutput = FileHandle.nullDevice
        sentinel.standardError = FileHandle.nullDevice
        try? sentinel.run()
    }

    /// The watcher: waits for `parent` to end, then restores whatever it left changed (nothing after a normal Quit).
    static func runSentinel(parent: pid_t, suite: String) -> Never {
        signal(SIGTERM, SIG_IGN)
        let store = suite.isEmpty ? UserDefaults.standard : UserDefaults(suiteName: suite) ?? .standard
        func restore() -> Never {
            DesktopSystemSettings(preferences: .system, store: store).restore(onlyFor: parent)
            exit(0)
        }
        let exited = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        exited.setEventHandler { restore() }
        exited.resume()
        // It may have ended before the watch began.
        if kill(parent, 0) != 0 && errno == ESRCH { restore() }
        dispatchMain()
    }
}
