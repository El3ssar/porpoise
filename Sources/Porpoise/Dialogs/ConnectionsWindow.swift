import AppKit
import PorpoiseCore
import PorpoiseServices

/// Go › Connections…: the saved servers. A list on the left; on the right the selected connection's settings, what is
/// known about it (the server's key, the ssh agent, where ~/.ssh/config sends it) and what it can do. Passwords and
/// secret keys go to the Keychain; the list itself never holds one.
final class ConnectionsWindow: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The window on screen, for the test bridge and so the menu brings it back.
    private(set) static var current: ConnectionsWindow?

    private let profiles: ConnectionProfiles
    private let credentials: ConnectionCredentials
    /// Opens a location in the window the Connections window was opened from.
    private let open: (URL) -> Void
    /// Reads ~/.ssh/config (tests give their own).
    private let sshConfig: () -> SSHConfig

    private let table = NSTableView()
    private let editor = NSStackView()
    private let removeButton = NSButton()
    private let importButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var form: ConnectionForm?
    private var selectedID: UUID?
    private var changeObserver: NSObjectProtocol?

    /// Shows the window; with `adding`, a new connection of that kind to fill in.
    @discardableResult
    static func show(adding kind: ConnectionProfile.Kind? = nil, open: @escaping (URL) -> Void) -> ConnectionsWindow {
        let w: ConnectionsWindow
        if let shown = current, shown.window?.isVisible == true {
            w = shown
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            w = ConnectionsWindow(profiles: .shared, credentials: .shared, open: open)
            current = w
            w.present()
        }
        if let kind { w.addProfile(kind: kind) }
        return w
    }

    init(
        profiles: ConnectionProfiles, credentials: ConnectionCredentials, sshConfig: @escaping () -> SSHConfig = { SSHConfig.load() },
        open: @escaping (URL) -> Void
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.sshConfig = sshConfig
        self.open = open
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Connections"
        w.minSize = CGSize(width: 720, height: 460)
        w.setFrameAutosaveName("Connections")
        super.init(window: w)
        build()
        changeObserver = NotificationCenter.default.addObserver(forName: ConnectionProfiles.changed, object: profiles, queue: .main) {
            [weak self] _ in self?.reload()
        }
        reload()
        if let first = profiles.profiles.first { select(first.id) } else { showEmpty() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { changeObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        table.setAccessibilityLabel("Saved connections")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add") ?? NSImage()
        let add = NSButton(image: plus, target: self, action: #selector(addProfile(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
        removeButton.target = self
        removeButton.action = #selector(removeProfile(_:))
        for b in [add, removeButton] { b.bezelStyle = .smallSquare; b.widthAnchor.constraint(equalToConstant: 26).isActive = true }
        importButton.addItem(withTitle: "Import from SSH Config")
        importButton.controlSize = .small
        importButton.target = self
        importButton.action = #selector(importAlias(_:))
        importButton.setAccessibilityLabel("Import a host from ~/.ssh/config")
        let buttons = NSStackView(views: [add, removeButton, NSView(), importButton])
        buttons.spacing = 0

        let left = NSStackView(views: [scroll, buttons])
        left.orientation = .vertical
        left.spacing = 6
        left.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 12
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(editor)
        editorScroll.documentView = flipped
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            editor.topAnchor.constraint(equalTo: flipped.topAnchor),
            editor.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: editorScroll.contentView.widthAnchor),
        ])

        let split = NSStackView(views: [left, editorScroll])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 18
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            left.heightAnchor.constraint(equalTo: split.heightAnchor),
            editorScroll.heightAnchor.constraint(equalTo: split.heightAnchor),
        ])
    }

    private func reload() {
        let keep = selectedID
        table.reloadData()
        if let keep, let row = profiles.profiles.firstIndex(where: { $0.id == keep }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        removeButton.isEnabled = selectedID.map { profiles.profile($0) != nil } ?? false
        rebuildImportMenu()
    }

    /// ~/.ssh/config hosts not saved yet, each with where it leads.
    private func rebuildImportMenu() {
        while importButton.numberOfItems > 1 { importButton.removeItem(at: 1) }
        let saved = Set(profiles.profiles.compactMap(\.sshAlias))
        let hosts = sshConfig().hosts.filter { !saved.contains($0.alias) }
        for h in hosts {
            var title = h.alias
            if h.hostName != h.alias { title += " — " + h.hostName }
            if !h.proxyJump.isEmpty { title += " via " + h.proxyJump.joined(separator: " → ") }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = h.alias
            importButton.menu?.addItem(item)
        }
        importButton.isEnabled = !hosts.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profiles.profiles[row]
        let name = NSTextField(labelWithString: p.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(p.kind.title) · \(p.address)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(p.kind), accessibilityDescription: p.kind.title) ?? NSImage())
        let row = NSStackView(views: [icon, text])
        row.spacing = 8
        row.identifier = NSUserInterfaceItemIdentifier(p.id.uuidString)
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < profiles.profiles.count else { return }
        let id = profiles.profiles[row].id
        if id != selectedID { select(id) }
    }

    static func symbol(_ kind: ConnectionProfile.Kind) -> String {
        switch kind {
        case .sftp: return "terminal"
        case .ftp, .ftps: return "arrow.up.arrow.down"
        case .smb: return "pc"
        case .s3: return "cylinder.split.1x2"
        }
    }

    // MARK: Editing

    /// Shows `id`'s settings (a profile not saved yet when it isn't in the list).
    func select(_ id: UUID, unsaved: ConnectionProfile? = nil) {
        selectedID = id
        guard let p = unsaved ?? profiles.profile(id) else { return showEmpty() }
        if let row = profiles.profiles.firstIndex(where: { $0.id == id }), table.selectedRow != row {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        removeButton.isEnabled = unsaved == nil
        let f = ConnectionForm(profile: p, hasSecret: credentials.hasSecret(for: p), aliases: Set(sshConfig().aliases))
        f.onKindChange = { [weak self] in self?.showForm(f) }
        form = f
        showForm(f)
    }

    private func showForm(_ f: ConnectionForm) {
        editor.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let save = NSButton(title: "Save", target: self, action: #selector(saveProfile(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectProfile(_:)))
        connect.keyEquivalent = "\r"
        f.problemLabel.textColor = .systemRed
        let buttons = NSStackView(views: [f.problemLabel, NSView(), save, connect])
        for v in [f.view, buttons, ConnectionInfoView(profile: f.draft, credentials: credentials)] { editor.addArrangedSubview(v) }
        buttons.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
    }

    private func showEmpty() {
        selectedID = nil
        form = nil
        editor.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "No saved connections")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(
            wrappingLabelWithString: "Save SFTP, FTP, SMB and S3 servers here to reach them from the sidebar. "
                + "Hosts in ~/.ssh/config can be imported with their jump hosts.")
        body.textColor = .secondaryLabelColor
        editor.addArrangedSubview(title)
        editor.addArrangedSubview(body)
        removeButton.isEnabled = false
    }

    /// The Import menu's titles (tests).
    var importTitles: [String] { importButton.itemTitles.dropFirst().map { $0 } }

    /// Imports the menu's `index`th host (tests; the menu does it on choosing).
    func importHost(at index: Int) {
        importButton.selectItem(at: index + 1)
        importAlias(importButton)
    }

    var rowCount: Int { table.numberOfRows }

    @objc func addProfile(_ sender: Any?) { addProfile(kind: .sftp) }

    func addProfile(kind: ConnectionProfile.Kind) {
        let p = ConnectionProfile(name: "New Connection", kind: kind)
        table.deselectAll(nil)
        select(p.id, unsaved: p)
        if let f = form { window?.makeFirstResponder(f.firstField) }
    }

    @objc private func importAlias(_ sender: NSPopUpButton) {
        guard let alias = sender.selectedItem?.representedObject as? String else { return }
        let p = ConnectionProfile(sshHost: sshConfig().resolve(alias))
        profiles.save(p)
        select(p.id)
    }

    @objc private func removeProfile(_ sender: Any?) {
        guard let id = selectedID, let p = profiles.profile(id) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)”?"
        a.informativeText = p.kind == .s3 ? "Its secret key is removed from the Keychain too." : "It's removed from the sidebar."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard let window else { return }
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.profiles.remove(id)
            if let next = self.profiles.profiles.first { self.select(next.id) } else { self.showEmpty() }
        }
    }

    /// Saves the form; false (with the reason shown) when it isn't complete.
    @discardableResult
    func saveForm() -> Bool {
        guard let f = form else { return false }
        let p = f.draft
        if let problem = p.problem {
            f.problemLabel.stringValue = problem
            return false
        }
        if !f.secret.isEmpty {
            do { try credentials.saveSecret(f.secret, for: p) } catch {
                f.problemLabel.stringValue = error.localizedDescription
                return false
            }
        }
        f.problemLabel.stringValue = ""
        profiles.save(p)
        select(p.id)
        return true
    }

    @objc private func saveProfile(_ sender: Any?) { if !saveForm() { NSSound.beep() } }

    @objc func connectProfile(_ sender: Any?) {
        guard saveForm(), let id = selectedID, let url = profiles.profile(id)?.url else { return NSSound.beep() }
        open(url)
    }
}

/// The fields of one profile; the kind decides which are shown.
final class ConnectionForm {
    let view = NSGridView()
    let problemLabel = NSTextField(labelWithString: "")
    var onKindChange: () -> Void = {}

    private var base: ConnectionProfile
    private let kind = NSPopUpButton()
    private let name = NSTextField()
    private let host = NSTextField()
    private let port = NSTextField()
    private let user = NSTextField()
    private let path = NSTextField()
    private let jumps = NSTextField()
    private let key = NSTextField()
    private let bucket = NSTextField()
    private let endpoint = NSTextField()
    private let region = NSTextField()
    private let accessKey = NSTextField()
    private let secretField = NSSecureTextField()

    /// The ~/.ssh/config Hosts: a server typed as one of them is kept as that alias.
    private let aliases: Set<String>

    var firstField: NSView { name }
    var secret: String { secretField.stringValue }

    init(profile: ConnectionProfile, hasSecret: Bool, aliases: Set<String> = Set(SSHConfig.load().aliases)) {
        base = profile
        self.aliases = aliases
        kind.addItems(withTitles: ConnectionProfile.Kind.allCases.map(\.title))
        kind.selectItem(at: ConnectionProfile.Kind.allCases.firstIndex(of: profile.kind) ?? 0)
        kind.target = self
        kind.action = #selector(kindChanged(_:))
        name.stringValue = profile.name
        host.stringValue = profile.sshAlias ?? profile.host
        port.stringValue = profile.port.map(String.init) ?? ""
        user.stringValue = profile.user ?? ""
        path.stringValue = profile.path
        jumps.stringValue = profile.jumpHosts.joined(separator: ", ")
        key.stringValue = profile.identityFile ?? ""
        bucket.stringValue = profile.bucket ?? ""
        endpoint.stringValue = profile.endpoint ?? ""
        region.stringValue = profile.region ?? ""
        accessKey.stringValue = profile.accessKeyID ?? ""
        secretField.placeholderString = hasSecret ? "Saved in the Keychain" : "Kept in the Keychain"
        problemLabel.lineBreakMode = .byWordWrapping
        layout()
    }

    private var selectedKind: ConnectionProfile.Kind { ConnectionProfile.Kind.allCases[max(0, kind.indexOfSelectedItem)] }

    /// Fills fields by their label ("Server:"), as a person would type them (tests).
    func type(_ values: [String: String]) {
        let fields: [String: NSTextField] = [
            "Name:": name, "Server:": host, "Port:": port, "User:": user, "Folder:": path, "Share:": path, "Prefix:": path, "Jump hosts:": jumps,
            "Key file:": key, "Bucket:": bucket, "Endpoint:": endpoint, "Region:": region, "Access key ID:": accessKey, "Password:": secretField,
            "Secret key:": secretField,
        ]
        for (label, value) in values { fields[label]?.stringValue = value }
    }

    /// Picks the kind, as the Type popup does.
    func choose(_ k: ConnectionProfile.Kind) {
        kind.selectItem(at: ConnectionProfile.Kind.allCases.firstIndex(of: k) ?? 0)
        kindChanged(nil)
    }

    /// The labels of the rows shown.
    var labels: [String] {
        (0..<view.numberOfRows).compactMap { (view.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue }
    }

    @objc private func kindChanged(_ sender: Any?) {
        base = draft
        layout()
        onKindChange()
    }

    private func layout() {
        while view.numberOfRows > 0 { view.removeRow(at: 0) }
        let k = selectedKind
        port.placeholderString = k.defaultPort.map(String.init) ?? ""
        user.placeholderString = k == .sftp && base.sshAlias != nil ? "From ~/.ssh/config" : NSUserName()
        host.placeholderString = "example.com, 192.168.1.10 or a ~/.ssh/config Host"
        path.placeholderString = k == .smb ? "Share/Folder" : (k == .s3 ? "Prefix (optional)" : "Folder (empty: home)")
        jumps.placeholderString = "user@bastion:22, second-hop"
        key.placeholderString = "Default keys and ssh-agent"
        endpoint.placeholderString = "https://s3.amazonaws.com"
        region.placeholderString = "us-east-1"
        var rows: [(String, NSView)] = [("Type:", kind), ("Name:", name)]
        switch k {
        case .s3:
            rows += [
                ("Endpoint:", endpoint), ("Region:", region), ("Bucket:", bucket), ("Prefix:", path), ("Access key ID:", accessKey),
                ("Secret key:", secretField),
            ]
        case .sftp:
            rows += [
                ("Server:", host), ("Port:", port), ("User:", user), ("Folder:", path), ("Jump hosts:", jumps), ("Key file:", key),
            ]
        case .smb:
            rows += [("Server:", host), ("Port:", port), ("User:", user), ("Share:", path), ("Password:", secretField)]
        case .ftp, .ftps:
            rows += [("Server:", host), ("Port:", port), ("User:", user), ("Folder:", path), ("Password:", secretField)]
        }
        for (label, field) in rows { view.addRow(with: [NSTextField(labelWithString: label), field]) }
        view.column(at: 0).xPlacement = .trailing
        view.rowAlignment = .firstBaseline
        view.columnSpacing = 8
        view.rowSpacing = 8
        for (_, field) in rows where field is NSTextField {
            if field.constraints.allSatisfy({ $0.firstAttribute != .width }) { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        }
    }

    /// The profile as the fields describe it now.
    var draft: ConnectionProfile {
        var p = base
        let k = selectedKind
        func text(_ f: NSTextField) -> String? {
            let t = f.stringValue.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        p.kind = k
        p.name = name.stringValue.trimmingCharacters(in: .whitespaces)
        let server = text(host) ?? ""
        // A name ~/.ssh/config knows stays an alias, so ssh reads its settings; anything else is an address.
        if k == .sftp, aliases.contains(server) {
            p.sshAlias = server
            p.host = server
        } else {
            p.sshAlias = nil
            p.host = server
        }
        p.port = text(port).flatMap(Int.init)
        p.user = text(user)
        p.path = text(path) ?? ""
        let hops = text(jumps)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        p.jumpHosts = k == .sftp ? hops : []
        p.identityFile = k == .sftp ? text(key) : nil
        p.bucket = k == .s3 ? text(bucket) : nil
        p.endpoint = k == .s3 ? text(endpoint) : nil
        p.region = k == .s3 ? text(region) : nil
        p.accessKeyID = k == .s3 ? text(accessKey) : nil
        return p
    }
}

/// What is known about a connection: the server's key, the agent, where ssh is sent, and what it can do. The ssh
/// lookups run in the background and fill in when done.
final class ConnectionInfoView: NSStackView {
    init(profile p: ConnectionProfile, credentials: ConnectionCredentials) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        if p.kind == .sftp, p.problem == nil {
            addArrangedSubview(Self.heading("Server"))
            let route = Self.line("Looking up ~/.ssh/config…")
            let keys = Self.line("")
            let agent = Self.line("")
            for v in [route, keys, agent] { addArrangedSubview(v) }
            DispatchQueue(label: "porpoise.connection-info").async {
                let options = ConnectionProfiles.sshOptions(for: p)
                let effective = HostKeys.effective(host: p.server, user: p.user, port: p.port, options: options)
                let known = HostKeys.known(host: p.server, user: p.user, port: p.port, options: options)
                let agentState = HostKeys.agent()
                DispatchQueue.main.async {
                    route.stringValue = Self.route(effective, profile: p)
                    keys.stringValue =
                        known.isEmpty
                        ? "Server key: not known yet. Its fingerprint is shown to you when you first connect."
                        : known.map { "Server key (\($0.type)): \($0.fingerprint)" }.joined(separator: "\n")
                    switch agentState {
                    case .keys(let n): agent.stringValue = "ssh-agent: \(n) key\(n == 1 ? "" : "s") available."
                    case .empty: agent.stringValue = "ssh-agent: running, with no keys added."
                    case .unavailable: agent.stringValue = "ssh-agent: not available; ssh uses your key files."
                    }
                }
            }
        } else if p.kind.storesSecret {
            addArrangedSubview(Self.heading("Login"))
            addArrangedSubview(
                Self.line(
                    credentials.hasSecret(for: p)
                        ? "The \(p.kind == .s3 ? "secret key" : "password") is saved in the Keychain."
                        : "Nothing saved yet: \(p.kind == .smb ? "macOS asks when it mounts the share" : "you're asked when connecting")."))
        }
        addArrangedSubview(Self.heading("What it can do"))
        for c in ConnectionCapability.report(for: p.kind) {
            let mark: String
            var text = c.name
            switch c.support {
            case .yes: mark = "✓"
            case .no: mark = "✗"
            case .partly(let note):
                mark = "~"
                text += " — " + note
            }
            addArrangedSubview(Self.line("\(mark)  \(text)"))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func route(_ e: HostKeys.Effective?, profile p: ConnectionProfile) -> String {
        guard let e else { return "ssh couldn't read the settings for \(p.server)." }
        var s = "Connects to \(e.hostName ?? p.server)"
        if let port = e.port, port != 22 { s += ":\(port)" }
        if let u = e.user { s += " as \(u)" }
        if !e.proxyJump.isEmpty { s += " via " + e.proxyJump.joined(separator: " → ") }
        return s + "."
    }

    private static func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        return t
    }

    private static func line(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.isSelectable = true
        t.preferredMaxLayoutWidth = 480
        return t
    }
}
