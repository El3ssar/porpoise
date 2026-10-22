import AppKit
import PorpoiseCore
import PorpoiseServices

/// Settings › Accounts: connected cloud accounts (+ / −), per account the sidebar rows, its name and storage, and one
/// app-wide choice, what Google Docs become when copied out.
enum AccountsSettingsPage {
    /// Documents that live only on the web (Google Docs, Sheets, Slides): shown while an account of a service that
    /// has them is connected.
    private static func webDocumentsSection(_ f: FormBuilder) {
        let before = f.stack.arrangedSubviews.count
        f.section("Google Docs, Sheets and Slides")
        let accounts = CloudAccounts.shared
        f.popup(
            "Copy them as:", CloudAccounts.exportPresets.map(\.title), CloudAccounts.exportPresets.firstIndex { $0.key == accounts.exportPreset } ?? 0
        ) {
            accounts.exportPreset = CloudAccounts.exportPresets[$0].key
        }
        _ = f.note("Copying a Google document out of Drive saves an export; the original stays in Drive. Opening one opens it in your browser.")
        let views = Array(f.stack.arrangedSubviews[before...])
        guard let first = views.first else { return }
        let follow = WebDocumentsVisibility(views)
        objc_setAssociatedObject(first, &WebDocumentsVisibility.key, follow, .OBJC_ASSOCIATION_RETAIN)
    }

    static func build(_ f: FormBuilder) {
        f.section("Cloud accounts")
        let page = AccountsView()
        f.stack.addArrangedSubview(page)
        page.widthAnchor.constraint(equalTo: f.stack.widthAnchor, constant: -60).isActive = true
        webDocumentsSection(f)
        offlineSection(f)
        f.section("Sign-in configuration")
        for descriptor in CloudProviderDescriptor.catalog {
            for configuration in descriptor.configurations {
                f.text(configuration.label, Settings.store.string(forKey: configuration.key) ?? "") {
                    Settings.store.set($0.trimmingCharacters(in: .whitespacesAndNewlines), forKey: configuration.key)
                }
            }
        }
        _ = f.note("Leave blank to use the application key included with this build.")
    }

    /// Downloads: how much space recently opened files may take, what each account has on this Mac, and where.
    static func offlineSection(_ f: FormBuilder) {
        guard CloudOfflineHub.service != nil else { return }
        f.section("On this Mac")
        let limits = CloudCommands.cacheLimits
        f.popup(
            "Recently opened files use up to:", items: { CloudCommands.cacheLimits.map(\.title) },
            limits.firstIndex { $0.bytes == CloudOfflineHub.service?.cacheLimit } ?? 1
        ) {
            CloudOfflineHub.service?.cacheLimit = limits[$0].bytes
        }
        _ = f.note("Files you download stay on this Mac until you choose Remove Download; they don’t count toward this.")
        let usage = OfflineUsageView()
        f.stack.addArrangedSubview(usage)
        usage.widthAnchor.constraint(equalTo: f.stack.widthAnchor, constant: -60).isActive = true
        if let root = CloudOfflineHub.service?.root {
            _ = f.note("Downloads are kept in \((root.path as NSString).abbreviatingWithTildeInPath).")
        }
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
                "Connect a cloud account to browse your files and shared folders in Porpoise, like any other folder.")
            text.preferredMaxLayoutWidth = 320
            let connect = ClosureButton(title: "Connect…") { [weak self] _ in self?.addAccount() }
            detail.addArrangedSubview(text)
            detail.addArrangedSubview(connect)
            return
        }
        let title = NSTextField(labelWithString: "\(a.provider.title) · \(a.email)")
        title.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .semibold)
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
            let c = NSButton(checkboxWithTitle: accounts.rootTitle(root, for: a.id), target: self, action: #selector(toggleRow(_:)))
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
        email.font = .systemFont(ofSize: Tokens.FontSize.callout, weight: .medium)
        email.lineBreakMode = .byTruncatingMiddle
        let sub: String
        switch a.status {
        case .signInNeeded: sub = "⚠︎ Needs sign-in"
        case .offline: sub = "Offline"
        case .ok: sub = a.quotaUsed.map { QuotaBar.text(used: $0, total: a.quotaTotal) } ?? a.provider.title
        }
        let subtitle = NSTextField(labelWithString: sub)
        subtitle.font = .systemFont(ofSize: Tokens.FontSize.small)
        subtitle.lineBreakMode = .byTruncatingTail
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
            if case .success = result { NSApp.activate() }
            if case .failure(.failed(let message)) = result { Prompt.message("Couldn’t sign in again", detail: message, on: window) }
        }
    }

    /// Asks once, naming the places that point into the account (they go too), then signs out.
    static func confirmRemove(_ account: CloudAccount, window: NSWindow?) {
        let places = CloudAccounts.shared.places(of: account.id)
        var info =
            "Porpoise signs out of this \(account.provider.title) account and forgets its cache. Your files in \(account.provider.title) stay as they are."
        let usage = CloudOfflineHub.service?.usage(account: account.id)
        if let line = CloudCommands.signOutLine(bytes: (usage?.kept ?? 0) + (usage?.recent ?? 0), provider: account.provider.title) {
            info += "\n\n" + line
        }
        if !places.isEmpty {
            let names = places.prefix(5).map { "“\($0.title)”" }.joined(separator: ", ")
            info += "\n\nThese places point into it and are removed too: \(names)\(places.count > 5 ? "…" : "")."
        }
        Prompt.confirm("Remove \(account.email)?", detail: info, confirm: "Remove", destructive: true, on: window) { confirmed in
            guard confirmed else { return }
            for p in places { PlacesModel.shared.remove(p) }
            CloudAccounts.shared.remove(account.id) { _ in }
        }
    }

    /// The account's own web page (Drive in the browser, signed in as this account).
    static func openInBrowser(_ account: CloudAccount) {
        NSWorkspace.shared.open(account.provider.descriptor.webLink(account.provider.descriptor.homeURL, email: account.email))
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
        account.map { $0.provider.descriptor.webLink(link, email: $0.email) } ?? link
    }

    static func rename(_ account: CloudAccount, window: NSWindow?) {
        Prompt.text(
            "Rename Account", detail: "Shown after “\(account.provider.title)” in the sidebar when you have more than one account.",
            value: CloudAccounts.shared.label(account.id), confirm: "Rename", on: window
        ) { CloudAccounts.shared.setLabel(account.id, $0) }
    }
}

/// Per account: what's kept downloaded and what was recently opened, with a button to remove the recent ones. Follows
/// downloads and accounts as they change.
final class OfflineUsageView: NSStackView {
    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        for name in [CloudOfflineHub.changed, CloudAccounts.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        }
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let service = CloudOfflineHub.service else { return }
        let accounts = CloudAccounts.shared
        for a in accounts.accounts {
            let u = service.usage(account: a.id)
            let text = NSTextField(labelWithString: CloudCommands.usageText(u, account: "\(accounts.title(a.id)) · \(a.email)"))
            text.lineBreakMode = .byTruncatingMiddle
            let remove = ClosureButton(title: "Remove Recent Downloads") { _ in service.removeRecent(account: a.id) }
            remove.controlSize = .small
            remove.font = .systemFont(ofSize: Tokens.FontSize.small)
            remove.isEnabled = u.recent > 0
            let row = NSStackView(views: [text, remove])
            row.spacing = 10
            addArrangedSubview(row)
        }
    }
}

/// Hides the web documents section while no connected account's service has such documents.
private final class WebDocumentsVisibility {
    nonisolated(unsafe) static var key = 0
    private let views: [Weak]
    private var observer: NSObjectProtocol?
    private struct Weak { weak var view: NSView? }

    init(_ views: [NSView]) {
        self.views = views.map { Weak(view: $0) }
        update()
        observer = NotificationCenter.default.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    static var isShown: Bool { CloudAccounts.shared.accounts.contains { $0.provider.descriptor.hasWebDocuments } }

    private func update() {
        MainActor.assumeIsolated {
            let hidden = !Self.isShown
            for v in views { v.view?.isHidden = hidden }
        }
    }
}
