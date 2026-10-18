import AppKit
import PorpoiseCore
import PorpoiseServices

/// Asked when an SSH server's key isn't the one this Mac knows for it: the new key's fingerprint, and the choice. The
/// safe answer is the default, since a changed key can mean someone is in between.
enum HostKeyChangePrompt {
    static func ask(server: String, change: HostKeyFingerprint.Change) -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "The identity of \(server) has changed"
        a.informativeText = """
            The server presents a different key than the one this Mac knows for it. This happens when a server is \
            reinstalled or its address is reused, but it can also mean someone is intercepting the connection.

            New \(change.keyType ?? "") key fingerprint:
            \(change.fingerprint)

            Connect only if you know the key was changed and this fingerprint is the server's (ask its administrator).
            """
        a.addButton(withTitle: "Don't Connect")
        a.addButton(withTitle: "Trust New Key")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn
    }
}
