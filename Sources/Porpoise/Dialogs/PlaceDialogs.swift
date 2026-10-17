import AppKit
import PorpoiseCore
import PorpoiseServices

/// "Edit Places Entry" dialog (label + location).
enum PlaceEditDialog {
    static func run(title: String, label: String, url: URL, window: NSWindow?, done: @escaping (String, URL) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 58))
        let l1 = NSTextField(labelWithString: "Label:"); l1.frame = CGRect(x: 0, y: 34, width: 70, height: 20)
        let f1 = NSTextField(string: label); f1.frame = CGRect(x: 74, y: 32, width: 286, height: 24)
        let l2 = NSTextField(labelWithString: "Location:"); l2.frame = CGRect(x: 0, y: 4, width: 70, height: 20)
        let f2 = NSTextField(string: url.isFileURL ? url.path : url.absoluteString); f2.frame = CGRect(x: 74, y: 2, width: 286, height: 24)
        [l1, f1, l2, f2].forEach(v.addSubview)
        a.accessoryView = v
        a.window.initialFirstResponder = f1
        let handler: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            let raw = f2.stringValue.trimmingCharacters(in: .whitespaces)
            let u = location(raw, old: url)
            let label = f1.stringValue.trimmingCharacters(in: .whitespaces)
            done(label.isEmpty ? defaultLabel(for: u) : label, u)
        }
        a.runSheet(for: window, handler)
    }

    /// The typed location: unchanged text (or none) keeps the old URL, so virtual places such as "recent:/files" or
    /// "network:/" survive editing only the label; "scheme:…" is a URL; anything else is a path ("~" expanded).
    private static func location(_ raw: String, old: URL) -> URL {
        if raw.isEmpty || raw == (old.isFileURL ? old.path : old.absoluteString) { return old }
        if raw.hasPrefix("file://"), let u = URL(string: raw), u.isFileURL { return u }
        if let remote = RemoteFS.parseTyped(raw) { return remote }  // sftp://…, user@host:path
        if !raw.hasPrefix("/"), !raw.hasPrefix("~"), let u = URL(string: raw), let scheme = u.scheme, scheme.count > 1 { return u }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private static func defaultLabel(for u: URL) -> String {
        let name = u.lastPathComponent
        if name.isEmpty || name == "/" { return u.isFileURL ? "/" : (u.host ?? u.absoluteString) }
        return name
    }
}
