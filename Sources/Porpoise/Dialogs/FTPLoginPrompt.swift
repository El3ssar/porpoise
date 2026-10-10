import AppKit
import PorpoiseServices

/// The login FTP providers ask for when a server refuses them (`RemoteFS.askLogin`).
enum FTPLoginPrompt {
    static func ask(host: String, user: String?) -> (user: String, password: String)? {
        let a = NSAlert()
        a.messageText = "Log in to \(host)"
        a.informativeText = "Enter your user name and password for this FTP server."
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        let u = NSTextField(frame: CGRect(x: 0, y: 32, width: 280, height: 24)); u.placeholderString = "User name"; u.stringValue = user ?? ""
        let p = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24)); p.placeholderString = "Password"
        v.addSubview(u); v.addSubview(p)
        a.accessoryView = v
        a.addButton(withTitle: "Log In")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = user == nil ? u : p
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return (u.stringValue, p.stringValue)
    }
}
