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
        if let w = window { a.beginSheetModal(for: w, completionHandler: handler) } else { handler(a.runModal()) }
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

/// Dolphin's "Add Network Folder" wizard (also the Mac's "Connect to Server…", ⌘K).
enum AddNetworkFolderDialog {
    static let kinds: [(title: String, scheme: String, port: Int)] = [
        ("SSH / SFTP", "sftp", 22), ("FTP", "ftp", 21), ("FTPS (FTP over TLS)", "ftps", 21),
        ("Windows share (SMB)", "smb", 445), ("WebDAV", "webdav", 80), ("WebDAV (secure)", "webdavs", 443),
        ("NFS", "nfs", 2049), ("Apple file server (AFP)", "afp", 548),
    ]

    static func run(window: NSWindow?, open: ((URL) -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = "Add Network Folder"
        a.informativeText = "Connect to a server and add it to Places."
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 210))
        func label(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = CGRect(x: 0, y: y + 3, width: 96, height: 18)
            v.addSubview(l)
        }
        func field(_ y: CGFloat, _ placeholder: String) -> NSTextField {
            let f = NSTextField(frame: CGRect(x: 104, y: y, width: 276, height: 24))
            f.placeholderString = placeholder
            v.addSubview(f)
            return f
        }
        label("Type:", 180)
        let type = NSPopUpButton(frame: CGRect(x: 102, y: 178, width: 280, height: 26), pullsDown: false)
        type.addItems(withTitles: kinds.map(\.title))
        v.addSubview(type)
        label("Name:", 146); let name = field(146, "My server")
        label("Server:", 116); let server = field(116, "example.com or 192.168.1.10")
        label("Port:", 86); let port = field(86, "22")
        label("User:", 56); let user = field(56, NSUserName())
        label("Folder:", 26); let folder = field(26, "/home/me or share name")
        let add = NSButton(checkboxWithTitle: "Add to Places", target: nil, action: nil)
        add.state = .on
        add.frame = CGRect(x: 102, y: 0, width: 200, height: 20)
        v.addSubview(add)
        a.accessoryView = v
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = server
        let handler: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn, !server.stringValue.isEmpty else { return }
            let k = kinds[type.indexOfSelectedItem]
            var c = URLComponents()
            c.scheme = k.scheme
            c.host = server.stringValue.trimmingCharacters(in: .whitespaces)
            if let p = Int(port.stringValue), p != k.port { c.port = p }
            if !user.stringValue.isEmpty { c.user = user.stringValue }
            var path = folder.stringValue.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty && !path.hasPrefix("/") { path = (k.scheme == "sftp" ? "/~/" : "/") + path }
            c.path = path.isEmpty ? "/" : path
            guard let url = c.url else { return }
            if add.state == .on { PlacesModel.shared.add(url, title: name.stringValue.isEmpty ? nil : name.stringValue) }
            if let open { open(url) } else if let wc = window?.windowController as? MainWindowController { wc.view.setURL(url) }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handler) } else { handler(a.runModal()) }
    }
}
