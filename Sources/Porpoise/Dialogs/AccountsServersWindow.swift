import AppKit
import PorpoiseCore
import PorpoiseServices

/// Go › Accounts & Servers… (⌥⌘K) and Settings › Accounts & Servers: every cloud account and saved server in one list
/// on the left; on the right the selected one's settings. For a server, also what is known about it (the server's
/// key, the ssh agent, where ~/.ssh/config sends it) and what it can do. Passwords and secret keys go to the Keychain;
/// the list itself never holds one. ⌘K stays the quick Connect sheet, which "+" also opens for a cloud account.
final class AccountsServersWindow: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The window on screen, for the test bridge and so the menu brings it back.
    private(set) static var current: AccountsServersWindow?

    /// A row of the list: a section heading, a cloud account (by id) or a saved server.
    enum Entry: Equatable {
        case heading(String)
        case account(String)
        case server(UUID)
    }

    static let accountsHeading = "Cloud Accounts"
    /// The height of the bar of buttons under the list.
    static let barHeight: CGFloat = 22
    static let serversHeading = "Servers"

    private var accounts: CloudAccounts { .shared }
    private let profiles: ConnectionProfiles
    private let credentials: ConnectionCredentials
    /// Where Connect opens a server: the window that asked last (an earlier one may have closed since).
    private(set) var open: (URL) -> Void
    /// Reads ~/.ssh/config (tests give their own).
    private let sshConfig: () -> SSHConfig

    private let table = NSTableView()
    private let editor = NSStackView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let importButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var entries: [Entry] = []
    /// The row shown on the right (a server not saved yet is shown without being in the list).
    private(set) var selection: Entry?
    private(set) var form: ConnectionForm?
    private(set) var accountDetail: AccountDetailView?
    /// The new server shown while it isn't saved yet.
    private var unsavedID: UUID?
    private var observers: [NSObjectProtocol] = []

    /// Shows the window; with `adding`, a new server of that kind to fill in; with `selecting`, that row.
    @discardableResult
    static func show(adding kind: ConnectionProfile.Kind? = nil, selecting entry: Entry? = nil, open: @escaping (URL) -> Void)
        -> AccountsServersWindow
    {
        let w: AccountsServersWindow
        if let shown = current, shown.window?.isVisible == true {
            w = shown
            w.open = open
            NSApp.activate()
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            w = AccountsServersWindow(profiles: .shared, credentials: .shared, open: open)
            current = w
            w.present()
        }
        if let kind { w.addProfile(kind: kind) } else if let entry { w.select(entry) }
        return w
    }

    /// Shown from Settings or the sidebar: servers open in the browser window in front.
    static func showFromFront(selecting entry: Entry? = nil) { show(selecting: entry, open: opener(owner: frontBrowser())) }

    /// Where a server opened from here goes: `owner` (the window that asked) while it's still open; once it has
    /// closed, the browser window in front then, or a new window. Held weakly, so a closed window is never navigated.
    static func opener(owner: MainWindowController?) -> (URL) -> Void {
        return { [weak owner] url in
            if let owner, owner.window?.isVisible == true { return owner.view.setURL(url) }
            if let front = frontBrowser() { return front.view.setURL(url) }
            AppDelegate.shared.newWindow(at: url)
        }
    }

    /// The browser window in front (Settings or this window may be in front of it), not whichever was opened first.
    static func frontBrowser() -> MainWindowController? {
        ViewContainer.frontBrowserWindow().flatMap { $0.windowController as? MainWindowController }
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
            contentRect: CGRect(x: 0, y: 0, width: 860, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Accounts & Servers"
        w.minSize = CGSize(width: 760, height: 480)
        w.setFrameAutosaveName("AccountsServers")
        super.init(window: w)
        build()
        for (name, object) in [(ConnectionProfiles.changed, profiles as AnyObject), (CloudAccounts.changed, nil), (CloudOfflineHub.changed, nil)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.reload() })
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        // Inset, not source list: a source list draws the system's grey material whatever background it is given, a
        // slab against the themed window. This list takes the theme's view color, in a rounded frame.
        table.style = .inset
        // Both headings drawn alike: a floating first heading gets a hairline the second doesn't.
        table.floatsGroupRows = false
        table.setAccessibilityLabel("Cloud accounts and saved servers")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Tokens.Radius.card
        scroll.layer?.borderWidth = 1
        scroll.layer?.masksToBounds = true
        Theme.whenChanged(scroll) { [weak scroll] in
            scroll?.layer?.backgroundColor = Theme.viewBackground.cgColor
            scroll?.layer?.borderColor = Theme.separator.cgColor
        }

        // "+" asks what to add: a cloud account (through the Connect sheet's sign-in) or a server to fill in here.
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.toolTip = "Add a cloud account or a server"
        addButton.target = self
        addButton.action = #selector(showAddMenu(_:))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
        removeButton.toolTip = "Remove the selected account or server"
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        // One 22-pt bar under the list: + and − and the import pull-down, all square-bezelled, as System Settings does.
        for b in [addButton, removeButton] { b.bezelStyle = .smallSquare; b.widthAnchor.constraint(equalToConstant: 26).isActive = true }
        importButton.addItem(withTitle: "Import from SSH Config")
        importButton.bezelStyle = .smallSquare
        for b in [addButton, removeButton, importButton] { b.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true }
        importButton.target = self
        importButton.action = #selector(importAlias(_:))
        importButton.setAccessibilityLabel("Import a host from ~/.ssh/config")
        let buttons = NSStackView(views: [addButton, removeButton, NSView(), importButton])
        buttons.spacing = 0

        let left = NSStackView(views: [scroll, buttons])
        left.orientation = .vertical
        left.spacing = 6
        left.widthAnchor.constraint(equalToConstant: 270).isActive = true
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 12
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = false
        // The editor takes the width the list leaves, whatever its content's own width (the empty state's text).
        editorScroll.setContentHuggingPriority(.init(1), for: .horizontal)
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
        var rows: [Entry] = [.heading(Self.accountsHeading)]
        rows += accounts.accounts.map { .account($0.id) }
        rows.append(.heading(Self.serversHeading))
        rows += profiles.profiles.map { .server($0.id) }
        entries = rows
        table.reloadData()
        switch selection {
        case .account(let id) where accounts.account(id) != nil:
            selectRow(of: .account(id))
            // A quota or picture arriving mid-typing doesn't rebuild the field being typed in.
            if let detail = accountDetail, !detail.isEditing { detail.build() }
        case .server(let id) where profiles.profile(id) != nil:
            selectRow(of: .server(id))
        case .server(let id) where id == unsavedID:
            break  // a new server being filled in
        case .account, .server, nil:
            // Gone (signed out, removed elsewhere), or nothing shown yet: the first row there is, or the empty state.
            showFirstOrEmpty()
        case .heading:
            break
        }
        updateButtons()
        rebuildImportMenu()
    }

    private var selectableEntries: [Entry] { entries.filter { if case .heading = $0 { false } else { true } } }

    /// The first account or server there still is; the empty state only when there is none.
    private func showFirstOrEmpty() {
        let first = selectableEntries.first {
            switch $0 {
            case .account(let id): accounts.account(id) != nil
            case .server(let id): profiles.profile(id) != nil
            case .heading: false
            }
        }
        if let first { select(first) } else { showEmpty() }
    }

    private func selectRow(of entry: Entry) {
        guard let row = entries.firstIndex(of: entry), table.selectedRow != row else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func updateButtons() {
        switch selection {
        case .account(let id): removeButton.isEnabled = accounts.account(id) != nil
        case .server(let id): removeButton.isEnabled = profiles.profile(id) != nil
        default: removeButton.isEnabled = false
        }
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

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        self.tableView(tableView, isGroupRow: row) ? nil : EntryRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { self.tableView(tableView, isGroupRow: row) ? 26 : 40 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .heading(let title):
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: Tokens.FontSize.small, weight: .semibold)
            t.textColor = .secondaryLabelColor
            t.setAccessibilityRole(.staticText)
            return t
        case .account(let id):
            guard let a = accounts.account(id) else { return nil }
            let sub: String
            switch a.status {
            case .signInNeeded: sub = "Needs sign-in"
            case .offline: sub = "Offline"
            case .ok: sub = a.quotaUsed.map { QuotaBar.text(used: $0, total: a.quotaTotal) } ?? a.provider.title
            }
            let pic = NSImageView(image: BrandMarks.avatar(accounts.avatar(id), name: a.displayName, email: a.email, size: 26))
            let mark = NSImageView(image: BrandMarks.image(a.provider.brand, size: 12) ?? NSImage())
            mark.translatesAutoresizingMaskIntoConstraints = false
            pic.addSubview(mark)
            NSLayoutConstraint.activate([
                pic.widthAnchor.constraint(equalToConstant: 26), pic.heightAnchor.constraint(equalToConstant: 26),
                mark.trailingAnchor.constraint(equalTo: pic.trailingAnchor, constant: 3),
                mark.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: 3),
            ])
            return Self.row(icon: pic, title: a.email, detail: sub, id: id, warning: a.status == .signInNeeded)
        case .server(let id):
            guard let p = profiles.profile(id) else { return nil }
            let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(p.kind), accessibilityDescription: p.kind.title) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: EntryCellView.symbolSize, weight: .regular)
            return Self.row(icon: icon, title: p.name, detail: "\(p.kind.title) · \(p.address)", id: p.id.uuidString)
        }
    }

    private static func row(icon: NSView, title: String, detail: String, id: String, warning: Bool = false) -> NSView {
        let row = EntryCellView(icon: icon, title: title, detail: detail, warning: warning)
        row.identifier = NSUserInterfaceItemIdentifier(id)
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < entries.count, entries[row] != selection else { return }
        select(entries[row])
    }

    static func symbol(_ kind: ConnectionProfile.Kind) -> String {
        switch kind {
        case .sftp: return "terminal"
        case .ftp, .ftps: return "arrow.up.arrow.down"
        case .smb: return "pc"
        case .s3: return "cylinder.split.1x2"
        }
    }

    // MARK: Showing a row

    /// Shows the row's settings: an account's, or a server's form.
    func select(_ entry: Entry) {
        switch entry {
        case .heading: return
        case .account(let id): showAccount(id)
        case .server(let id): select(id)
        }
    }

    private func showAccount(_ id: String) {
        guard accounts.account(id) != nil else { return showFirstOrEmpty() }
        selection = .account(id)
        form = nil
        selectRow(of: .account(id))
        editor.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let detail = AccountDetailView(accountID: id)
        accountDetail = detail
        editor.addArrangedSubview(detail)
        updateButtons()
    }

    /// Shows server `id`'s settings (a profile not saved yet when it isn't in the list).
    func select(_ id: UUID, unsaved: ConnectionProfile? = nil) {
        selection = .server(id)
        unsavedID = unsaved?.id
        accountDetail = nil
        guard let p = unsaved ?? profiles.profile(id) else { return showFirstOrEmpty() }
        if unsaved == nil { selectRow(of: .server(id)) }
        let f = ConnectionForm(profile: p, hasSecret: credentials.hasSecret(for: p), aliases: Set(sshConfig().aliases))
        f.onKindChange = { [weak self] in self?.showForm(f) }
        form = f
        showForm(f)
        updateButtons()
    }

    private func showForm(_ f: ConnectionForm) {
        editor.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let save = NSButton(title: "Save", target: self, action: #selector(saveProfile(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectProfile(_:)))
        connect.keyEquivalent = "\r"
        f.problemLabel.textColor = .systemRed
        f.problemLabel.lineBreakMode = .byWordWrapping
        f.problemLabel.maximumNumberOfLines = 0
        let buttons = NSStackView(views: [f.problemLabel, NSView(), save, connect])
        for v in [f.view, buttons, ConnectionInfoView(profile: f.draft, credentials: credentials)] { editor.addArrangedSubview(v) }
        buttons.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
    }

    private func showEmpty() {
        selection = nil
        form = nil
        accountDetail = nil
        table.deselectAll(nil)
        editor.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // A designed empty state, centered: what this window is for and the things to do next.
        let symbol = NSImageView(
            image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 40, weight: .light)) ?? NSImage())
        symbol.contentTintColor = Theme.windowTextInactive
        let title = NSTextField(labelWithString: "No accounts or servers")
        title.font = .systemFont(ofSize: Tokens.FontSize.title2, weight: .semibold)
        title.textColor = Theme.windowText
        let body = NSTextField(
            wrappingLabelWithString: "Connect a cloud account, or save SFTP, FTP, SMB and S3 servers, to reach them from the sidebar. "
                + "Hosts in ~/.ssh/config can be imported with their jump hosts.")
        body.textColor = Theme.windowTextInactive
        body.alignment = .center
        body.preferredMaxLayoutWidth = 380
        let cloud = NSButton(title: "Connect Cloud Account…", target: self, action: #selector(addAccount(_:)))
        cloud.setAccessibilityIdentifier("accounts-empty-cloud")
        let add = NSButton(title: "Add Server", target: self, action: #selector(addProfile(_:)))
        add.keyEquivalent = "\r"
        add.setAccessibilityIdentifier("connections-empty-add")
        for b in [cloud, add] {
            b.bezelStyle = .rounded
            b.controlSize = .large
        }
        let actions = NSStackView(views: [cloud, add])
        actions.spacing = 12
        let column = NSStackView(views: [symbol, title, body, actions])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(16, after: body)
        column.edgeInsets = NSEdgeInsets(top: 96, left: 0, bottom: 0, right: 0)
        editor.addArrangedSubview(column)
        column.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        updateButtons()
    }

    // MARK: Adding and removing

    /// The Import menu's titles (tests).
    var importTitles: [String] { importButton.itemTitles.dropFirst().map { $0 } }

    /// Imports the menu's `index`th host (tests; the menu does it on choosing).
    func importHost(at index: Int) {
        importButton.selectItem(at: index + 1)
        importAlias(importButton)
    }

    /// The saved servers listed.
    var serverRowCount: Int { entries.filter { if case .server = $0 { true } else { false } }.count }

    /// The cloud accounts listed.
    var accountRowCount: Int { entries.filter { if case .account = $0 { true } else { false } }.count }

    /// "+"'s menu: what can be added.
    func addMenu() -> NSMenu {
        let menu = NSMenu(title: "Add")
        let cloud = NSMenuItem(title: "Cloud Account…", action: #selector(addAccount(_:)), keyEquivalent: "")
        let server = NSMenuItem(title: "Server", action: #selector(addProfile(_:)), keyEquivalent: "")
        for item in [cloud, server] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    /// The Connect sheet on this window, for its cloud sign-in; the account appears in the list when it's connected.
    @objc func addAccount(_ sender: Any?) {
        ConnectSheet.run(window: window) { [weak self] url in self?.open(url) }
    }

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
        do {
            try profiles.save(p).get()
            select(p.id)
        } catch {
            select(p.id, unsaved: p)
            form?.problemLabel.stringValue = "Connection wasn’t saved. " + error.localizedDescription + " Try Save again."
        }
    }

    /// "−": signs out of the selected account, or removes the selected server, after asking.
    @objc func removeSelected(_ sender: Any?) {
        switch selection {
        case .account(let id):
            guard let a = accounts.account(id) else { return }
            AccountActions.confirmRemove(a, window: window)
        case .server:
            removeProfile()
        default: NSSound.beep()
        }
    }

    private func removeProfile() {
        guard case .server(let id) = selection, let p = profiles.profile(id) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)”?"
        a.informativeText = p.kind == .s3 ? "Its secret key is removed from the Keychain too." : "It's removed from the sidebar."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard let window else { return }
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            do { try self.profiles.remove(id).get() } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The connection couldn’t be removed completely."
                alert.beginSheetModal(for: window)
                return
            }
            self.showFirstOrEmpty()
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
        // The connection first: a secret saved for one that then failed to save would stay in the Keychain, orphaned.
        do { try profiles.save(p).get() } catch {
            f.problemLabel.stringValue = "Connection wasn’t saved. " + error.localizedDescription + " Try Save again."
            return false
        }
        if !f.secret.isEmpty {
            do { try credentials.saveSecret(f.secret, for: p) } catch {
                f.problemLabel.stringValue = "The connection was saved, but not its password: " + error.localizedDescription
                return false
            }
        }
        f.problemLabel.stringValue = ""
        select(p.id)
        return true
    }

    @objc private func saveProfile(_ sender: Any?) { if !saveForm() { NSSound.beep() } }

    @objc func connectProfile(_ sender: Any?) {
        guard saveForm(), case .server(let id) = selection, let url = profiles.profile(id)?.url else { return NSSound.beep() }
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
        t.font = .systemFont(ofSize: Tokens.FontSize.callout, weight: .semibold)
        return t
    }

    private static func line(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: Tokens.FontSize.callout)
        t.textColor = .secondaryLabelColor
        t.isSelectable = true
        t.preferredMaxLayoutWidth = 480
        return t
    }
}

/// A row of the list: AppKit's selection in the native theme; in a palette theme the palette's (its selection colour
/// as a tint with an outline, as in the file lists), under the palette's selection text.
final class EntryRowView: NSTableRowView {
    /// The inset table style's own margin either side of a selection.
    static let selectionInset: CGFloat = 10

    override func drawSelection(in dirtyRect: NSRect) {
        guard !Tokens.isNative else { return super.drawSelection(in: dirtyRect) }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Self.selectionInset, dy: 0.5), xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row)
        Theme.itemSelectedFill.setFill()
        path.fill()
        Theme.itemSelectedOutline.setStroke()
        path.stroke()
    }

    // A tint, not a solid fill: the cells keep their normal style and take the palette's selection text themselves.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { Tokens.isNative ? super.interiorBackgroundStyle : .normal }
}

/// One account or server in the list: a 26-pt icon slot (so every title starts at the same x), the name and a detail
/// line. Its text follows the row's selection, as a table cell's does.
final class EntryCellView: NSTableCellView {
    private let detail: NSTextField
    private let warning: NSImageView?

    init(icon: NSView, title: String, detail text: String, warning showsWarning: Bool) {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        detail = NSTextField(labelWithString: text)
        detail.font = .systemFont(ofSize: Tokens.FontSize.small)
        detail.lineBreakMode = .byTruncatingMiddle
        if showsWarning {
            let mark = NSImageView(
                image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") ?? NSImage())
            mark.symbolConfiguration = .init(pointSize: Tokens.FontSize.small, weight: .regular)
            warning = mark
        } else {
            warning = nil
        }
        super.init(frame: .zero)
        textField = name
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(icon)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: Self.iconSlot), slot.heightAnchor.constraint(equalToConstant: Self.iconSlot),
            icon.centerXAnchor.constraint(equalTo: slot.centerXAnchor), icon.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        let subRow = NSStackView(views: [warning, detail].compactMap { $0 })
        subRow.spacing = 3
        let text = NSStackView(views: [name, subRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [slot, text])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        backgroundStyleChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The avatar's size: server symbols are centred in the same square.
    static let iconSlot: CGFloat = 26
    /// Server symbols at the sidebar's symbol size (design contract I1).
    static let symbolSize: CGFloat = 16

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { backgroundStyleChanged() }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        backgroundStyleChanged()
    }

    /// On the selection, the selection's text colour (the detail at 80 %); otherwise the window's text colours. In a
    /// palette theme the row draws a tint and keeps its style normal (EntryRowView), so there a selected row counts
    /// whatever its style.
    private func backgroundStyleChanged() {
        let rowSelected = (superview as? NSTableRowView)?.isSelected == true
        let selected = backgroundStyle == .emphasized || (rowSelected && !Tokens.isNative)
        guard selected != showsSelection else { return }  // called on every draw: only a change recolours
        showsSelection = selected
        textField?.textColor = selected ? Theme.selectionText : Theme.windowText
        detail.textColor = selected ? Theme.selectionText.withAlphaComponent(0.8) : Theme.windowTextInactive
        warning?.contentTintColor = selected ? Theme.selectionText : .systemYellow
    }

    /// Whether the text shows the selection's colours now (nil until first coloured).
    private var showsSelection: Bool?

    /// The colours the name and detail show now (tests).
    var colors: (title: NSColor?, detail: NSColor?) { (textField?.textColor, detail.textColor) }
}
