import AppKit
import PorpoiseServices

/// Settings › Advanced › Administrator helper (W-245): whether Porpoise's helper is installed and current, what each
/// kind of approval means, and a way to remove it.
@MainActor enum HelperSettings {
    /// What the helper is, read off the main thread (checking the installed copy's signature reads its files).
    enum State: Equatable {
        case checking, administratorsOnly, notInstalled, outdated, installed(fullDiskAccess: Bool?)

        var line: (Bool?, String) {
            switch self {
            case .checking: return (nil, "Checking…")
            case .administratorsOnly:
                return (nil, "For administrators only. Porpoise asks for an administrator’s name and password when an action needs it.")
            case .notInstalled: return (nil, "Not installed. It’s installed the first time an action needs it (one approval).")
            case .outdated: return (false, "An update of the helper is ready: it’s installed with the next action that needs it.")
            case .installed(let fda):
                return fda == false
                    ? (false, "Installed. Switch Porpoise Helper on under Full Disk Access to change items in protected folders.")
                    : (true, "Installed and up to date.")
            }
        }

        var button: String {
            switch self {
            case .installed, .outdated: return "Uninstall Helper…"
            case .notInstalled: return "Install Helper…"
            case .checking, .administratorsOnly: return "Install Helper…"
            }
        }
    }

    private(set) static var state: State = .checking
    /// Seams for tests: what's read, and what the button does.
    static var read: @Sendable () -> State = {
        guard PrivilegedHelper.isForThisUser else { return .administratorsOnly }
        if PrivilegedHelper.isEnabled { return .installed(fullDiskAccess: PrivilegedHelper.hasFullDiskAccess) }
        return PrivilegedHelper.isOutdated ? .outdated : .notInstalled
    }
    static var uninstall: @Sendable () -> Void = { PrivilegedHelper.disable() }
    static var install: (@escaping () -> Void) -> Void = { done in HelperSetup.install(then: done) }

    static let tiers = [
        "Standard approval — changing items that belong to the system, other people or another volume (an app in Applications, a file in /Library): Touch ID or your password once, then 5 minutes without asking.",
        "Protected approval — system settings, what runs when your Mac starts, other people’s files (an app another person installed, too), owners and setuid programs: asked every time, naming exactly what will change.",
        "Never — items macOS itself protects (System Integrity Protection), and requests from Shortcuts, scripts or the command line, which never use the helper.",
    ]

    /// Reads the state again in the background, then shows it.
    static func reload(_ done: @escaping () -> Void) {
        let read = read
        Task {
            let s = await Task.detached { read() }.value
            state = s
            done()
        }
    }

    static func build(_ f: FormBuilder) {
        f.section("Administrator helper")
        f.note(
            "Porpoise Helper does what only an administrator may: changing apps and items that belong to the system or other people. It does nothing without your approval for that action."
        )
        f.status("Status:", { state.line }, button: { state.button }) { refresh in
            switch state {
            case .installed, .outdated:
                guard confirmUninstall() else { return }
                let uninstall = uninstall
                Task {
                    await Task.detached { uninstall() }.value
                    reload(refresh)
                }
            case .notInstalled, .administratorsOnly, .checking:
                install { reload(refresh) }
            }
        }
        for t in tiers { f.note(t) }
        f.observe(PrivacyAccess.statusChanged)
        reload { [weak f] in f?.refresh() }
    }

    private static func confirmUninstall() -> Bool {
        let a = NSAlert()
        a.messageText = "Uninstall Porpoise Helper?"
        a.informativeText =
            "Porpoise will ask for an administrator’s name and password whenever an action needs it, as macOS does. You can install the helper again here."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        return confirmForTesting?() ?? (a.runModal() == .alertFirstButtonReturn)
    }

    static var confirmForTesting: (() -> Bool)?
}
