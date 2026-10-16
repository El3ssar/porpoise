import AppKit
import PorpoiseCore
import PorpoiseServices

/// Settings › Accounts: connected cloud accounts (+ / −), per account the sidebar rows, its name and storage, and one
/// app-wide choice, what Google Docs become when copied out.
enum AccountsSettingsPage {
    static func build(_ f: FormBuilder) {
        f.section("Cloud accounts")
        let page = AccountsView()
        f.stack.addArrangedSubview(page)
        page.widthAnchor.constraint(equalTo: f.stack.widthAnchor, constant: -60).isActive = true
        f.section("Google Docs, Sheets and Slides")
        let accounts = CloudAccounts.shared
        f.popup(
            "Copy them as:", CloudAccounts.exportPresets.map(\.title), CloudAccounts.exportPresets.firstIndex { $0.key == accounts.exportPreset } ?? 0
        ) {
            accounts.exportPreset = CloudAccounts.exportPresets[$0].key
        }
        _ = f.note("Copying a Google document out of Drive saves an export; the original stays in Drive. Opening one opens it in your browser.")
    }

    /// The selected account in the page, for the test bridge.
    static weak var current: AccountsView?
}

/// The account list and the selected account's details, side by side.
final class AccountsView: NSView {
    private let list = NSStackView()
    private let detail = NSStackView()
    private let add = NSButton()
    private let remove = NSButton()
    private(set) var selected: String?
    private var nameField: NSTextField?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let listBox = NSBox()
        listBox.boxType = .custom
        listBox.cornerRadius = 8
        listBox.borderColor = .separatorColor
        listBox.fillColor = .controlBackgroundColor
        listBox.contentViewMargins = .zero
        listBox.contentView = list
        for (b, symbol, action, tip) in [
            (add, "plus", #selector(addAccount), "Connect an account"), (remove, "minus", #selector(removeAccount), "Remove the selected account"),
        ] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .smallSquare
            b.target = self
            b.action = action
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0
        let left = NSStackView(views: [listBox, buttons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 0
        listBox.widthAnchor.constraint(equalToConstant: 240).isActive = true
        listBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        let row = NSStackView(views: [left, detail])
        row.alignment = .top
        row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: CloudAccounts.changed, object: nil)
        AccountsSettingsPage.current = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        let accounts = CloudAccounts.shared.accounts
        if selected.flatMap(CloudAccounts.shared.account) == nil { selected = accounts.first?.id }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for a in accounts {
            let r = AccountRow(account: a, avatar: CloudAccounts.shared.avatar(a.id), selected: a.id == selected)
            r.onClick = { [weak self] in self?.select(a.id) }
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        if accounts.isEmpty {
            let empty = ConnectSheet.secondary("No accounts yet.")
            list.addArrangedSubview(empty)
        }
        remove.isEnabled = selected != nil
        buildDetail()
    }

    func select(_ id: String) {
        selected = id
        reload()
    }

    private func buildDetail() {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let accounts = CloudAccounts.shared
        guard let id = selected, let a = accounts.account(id) else {
            let text = ConnectSheet.secondary(
                "Connect Google Drive to browse My Drive, files shared with you and shared drives in Porpoise, like any other folder.")
            text.preferredMaxLayoutWidth = 320
            let connect = ClosureButton(title: "Connect…") { [weak self] _ in self?.addAccount() }
            detail.addArrangedSubview(text)
            detail.addArrangedSubview(connect)
            return
        }
        let title = NSTextField(labelWithString: "\(a.provider.title) · \(a.email)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let signIn = ClosureButton(title: "Sign In Again") { [weak self] _ in self?.signInAgain(id) }
        signIn.identifier = NSUserInterfaceItemIdentifier("signInAgain")
        if a.status == .signInNeeded { signIn.keyEquivalent = "\r" }
        detail.addArrangedSubview(ConnectSheet.row([title, signIn]))
        if let warning = Self.statusLine(a) { detail.addArrangedSubview(warning) }

        let name = NSTextField(string: accounts.label(id))
        name.placeholderString = accounts.label(id)
        name.target = self
        name.action = #selector(nameChanged(_:))
        name.widthAnchor.constraint(equalToConstant: 200).isActive = true
        nameField = name
        detail.addArrangedSubview(Self.labeled("Name in sidebar:", name))
        let note = ConnectSheet.secondary("Shown after “\(a.provider.title)” when you have more than one account.")
        note.preferredMaxLayoutWidth = 300
        detail.addArrangedSubview(Self.labeled("", note))

        var checks: [NSView] = []
        for root in accounts.availableRows(id) {
            let c = NSButton(checkboxWithTitle: root.title, target: self, action: #selector(toggleRow(_:)))
            c.identifier = NSUserInterfaceItemIdentifier(root.rawValue)
            c.state = accounts.shows(root, for: id) ? .on : .off
            checks.append(c)
        }
        let checkStack = NSStackView(views: checks)
        checkStack.orientation = .vertical
        checkStack.alignment = .leading
        checkStack.spacing = 6
        detail.addArrangedSubview(Self.labeled("Show in sidebar:", checkStack))
        if let quota = QuotaBar.make(used: a.quotaUsed, total: a.quotaTotal) { detail.addArrangedSubview(Self.labeled("Storage:", quota)) }
    }

    /// Trouble only: needs signing in again, or offline.
    static func statusLine(_ a: CloudAccount) -> NSView? {
        let (symbol, color, text): (String, NSColor, String)
        switch a.status {
        case .ok: return nil
        case .offline: (symbol, color, text) = ("icloud.slash", .secondaryLabelColor, "Offline. Porpoise reconnects by itself.")
        case .signInNeeded: (symbol, color, text) = ("exclamationmark.triangle.fill", .systemYellow, "Sign in again to keep using this account.")
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        return ConnectSheet.row([icon, ConnectSheet.secondary(text)])
    }

    private static func labeled(_ label: String, _ v: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let r = NSStackView(views: [l, v])
        r.alignment = .firstBaseline
        r.spacing = 8
        return r
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        guard let id = selected else { return }
        CloudAccounts.shared.setLabel(id, sender.stringValue)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard let id = selected, let raw = sender.identifier?.rawValue, let root = CloudRoot(rawValue: raw) else { return }
        CloudAccounts.shared.setShows(root, for: id, sender.state == .on)
    }

    @objc func addAccount() {
        let front = AppDelegate.shared.windows.first
        ConnectSheet.run(window: window) { url in front?.view.setURL(url) }
    }

    @objc func removeAccount() {
        guard let id = selected, let a = CloudAccounts.shared.account(id) else { return }
        AccountActions.confirmRemove(a, window: window)
    }

    private func signInAgain(_ id: String) { AccountActions.signInAgain(id, window: window) }
}

/// One account in the list: picture, email, and its storage or its trouble.
final class AccountRow: NSView {
    var onClick: (() -> Void)?
    private let isSelected: Bool

    init(account a: CloudAccount, avatar: Data?, selected: Bool) {
        isSelected = selected
        super.init(frame: .zero)
        let pic = NSImageView(image: BrandMarks.avatar(avatar, name: a.displayName, email: a.email, size: 26))
        let mark = NSImageView(image: BrandMarks.image(a.provider.brand, size: 12) ?? NSImage())
        mark.translatesAutoresizingMaskIntoConstraints = false
        pic.addSubview(mark)
        NSLayoutConstraint.activate([
            pic.widthAnchor.constraint(equalToConstant: 26), pic.heightAnchor.constraint(equalToConstant: 26),
            mark.trailingAnchor.constraint(equalTo: pic.trailingAnchor, constant: 3),
            mark.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: 3),
        ])
        let email = NSTextField(labelWithString: a.email)
        email.font = .systemFont(ofSize: 12, weight: .medium)
        email.lineBreakMode = .byTruncatingMiddle
        let sub: String
        switch a.status {
        case .signInNeeded: sub = "⚠︎ Needs sign-in"
        case .offline: sub = "Offline"
        case .ok: sub = a.quotaUsed.map { "\(a.provider.title) · \(QuotaBar.text(used: $0, total: a.quotaTotal))" } ?? a.provider.title
        }
        let subtitle = NSTextField(labelWithString: sub)
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        if selected { email.textColor = .alternateSelectedControlTextColor }
        let text = NSStackView(views: [email, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [pic, text])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityRole(.row)
        setAccessibilityLabel(a.email)
        setAccessibilitySelected(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// What the sidebar header's menu, Settings and the message bar do with an account.
enum AccountActions {
    /// Browser step only; paused work continues afterwards.
    static func signInAgain(_ id: String, window: NSWindow?) {
        _ = CloudAccounts.shared.signInAgain(id, openBrowser: ConnectSheet.openBrowser) { result in
            if case .failure(.failed(let message)) = result {
                let a = NSAlert()
                a.messageText = "Couldn’t sign in again"
                a.informativeText = message
                if let window { a.beginSheetModal(for: window) } else { a.runModal() }
            }
        }
    }

    /// Asks once, naming the places that point into the account (they go too), then signs out.
    static func confirmRemove(_ account: CloudAccount, window: NSWindow?) {
        let places = CloudAccounts.shared.places(of: account.id)
        let a = NSAlert()
        a.messageText = "Remove \(account.email)?"
        var info = "Porpoise signs out of this \(account.provider.title) account and forgets its cache. Nothing in your Drive changes."
        if !places.isEmpty {
            let names = places.prefix(5).map { "“\($0.title)”" }.joined(separator: ", ")
            info += "\n\nThese places point into it and are removed too: \(names)\(places.count > 5 ? "…" : "")."
        }
        a.informativeText = info
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        let done: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            for p in places { PlacesModel.shared.remove(p) }
            CloudAccounts.shared.remove(account.id) { _ in }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: done) } else { done(a.runModal()) }
    }

    /// The account's own web page (Drive in the browser, signed in as this account).
    static func openInBrowser(_ account: CloudAccount) {
        var c = URLComponents(string: "https://drive.google.com/drive/my-drive")!
        c.queryItems = [URLQueryItem(name: "authuser", value: account.email)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    /// Google Docs, Sheets, Slides…: web documents open in the browser, signed in as the account they're in.
    /// Returns false for anything else.
    static func openWebDocument(_ url: URL) -> Bool {
        guard let info = CloudAccounts.shared.info(for: url), info.isWebDocument, let link = info.webLink else { return false }
        NSWorkspace.shared.open(webLink(link, account: CloudAccounts.shared.account(for: url)))
        return true
    }

    /// `link` opened as `account` (Google's authuser), so a second signed-in account doesn't get it.
    static func webLink(_ link: URL, account: CloudAccount?) -> URL {
        guard let account, var c = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "authuser" } + [URLQueryItem(name: "authuser", value: account.email)]
        return c.url ?? link
    }

    static func rename(_ account: CloudAccount, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = "Rename Account"
        a.informativeText = "Shown after “\(account.provider.title)” in the sidebar when you have more than one account."
        let field = NSTextField(string: CloudAccounts.shared.label(account.id))
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn { CloudAccounts.shared.setLabel(account.id, field.stringValue) }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: done) } else { done(a.runModal()) }
    }
}
