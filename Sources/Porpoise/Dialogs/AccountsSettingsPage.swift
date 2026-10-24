import AppKit
import PorpoiseCore
import PorpoiseServices

/// Settings › Accounts & Servers: what the cloud accounts and saved servers are (each one's own settings are in the
/// Accounts & Servers window), and the app-wide choices: what Google Docs become when copied out, how much space
/// downloads may take, and the user's own sign-in registrations.
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
        f.section("Accounts and servers")
        f.status(
            "Connected:", { (nil, summary(CloudAccounts.shared.accounts.count, ConnectionProfiles.shared.profiles.count)) },
            button: { "Open Accounts & Servers…" }
        ) { _ in AccountsServersWindow.showFromFront() }
        f.observe(CloudAccounts.changed)
        f.observe(ConnectionProfiles.changed)
        _ = f.note("Each cloud account and saved server, with its own settings, is in the Accounts & Servers window (Go › Accounts & Servers…, ⌥⌘K).")
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

    /// "2 cloud accounts, 1 server".
    static func summary(_ accounts: Int, _ servers: Int) -> String {
        guard accounts + servers > 0 else { return "No cloud accounts or servers yet" }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return count(accounts, "cloud account") + ", " + count(servers, "server")
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
}

/// One cloud account's settings, in the Accounts & Servers window: its trouble, its name in the sidebar, the rows it
/// shows there, its storage and what it keeps on this Mac.
final class AccountDetailView: NSStackView {
    let accountID: String
    private(set) var nameField: NSTextField?

    init(accountID id: String) {
        accountID = id
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// True while the sidebar name is being typed: a quota or picture arriving then leaves the view as it is.
    var isEditing: Bool { nameField?.currentEditor() != nil }

    func build() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let accounts = CloudAccounts.shared
        guard let a = accounts.account(accountID) else { return }
        let title = NSTextField(labelWithString: "\(a.provider.title) · \(a.email)")
        title.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let signIn = ClosureButton(title: "Sign In Again") { [weak self] _ in
            guard let self else { return }
            AccountActions.signInAgain(self.accountID, window: self.window)
        }
        signIn.identifier = NSUserInterfaceItemIdentifier("signInAgain")
        if a.status == .signInNeeded { signIn.keyEquivalent = "\r" }
        addArrangedSubview(ConnectSheet.row([title, signIn]))
        if let warning = Self.statusLine(a) { addArrangedSubview(warning) }

        let name = NSTextField(string: accounts.label(accountID))
        name.placeholderString = accounts.label(accountID)
        name.target = self
        name.action = #selector(nameChanged(_:))
        name.widthAnchor.constraint(equalToConstant: 200).isActive = true
        name.setAccessibilityLabel("Name in sidebar")
        nameField = name
        addArrangedSubview(Self.labeled("Name in sidebar:", name))
        let note = ConnectSheet.secondary("Shown after “\(a.provider.title)” when you have more than one account.")
        note.preferredMaxLayoutWidth = 300
        addArrangedSubview(Self.labeled("", note))

        var checks: [NSView] = []
        for root in accounts.availableRows(accountID) {
            let c = NSButton(checkboxWithTitle: accounts.rootTitle(root, for: a.id), target: self, action: #selector(toggleRow(_:)))
            c.identifier = NSUserInterfaceItemIdentifier(root.rawValue)
            c.state = accounts.shows(root, for: accountID) ? .on : .off
            checks.append(c)
        }
        let checkStack = NSStackView(views: checks)
        checkStack.orientation = .vertical
        checkStack.alignment = .leading
        checkStack.spacing = 6
        addArrangedSubview(Self.labeled("Show in sidebar:", checkStack))
        if let quota = QuotaBar.make(used: a.quotaUsed, total: a.quotaTotal) { addArrangedSubview(Self.labeled("Storage:", quota)) }
        if let service = CloudOfflineHub.service {
            let u = service.usage(account: accountID)
            let text = ConnectSheet.secondary(CloudCommands.usageText(u, account: accounts.title(accountID)))
            text.preferredMaxLayoutWidth = 300
            let id = accountID
            let remove = ClosureButton(title: "Remove Recent Downloads") { _ in service.removeRecent(account: id) }
            remove.isEnabled = u.recent > 0
            let column = NSStackView(views: [text, remove])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            addArrangedSubview(Self.labeled("On this Mac:", column))
        }
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

    @objc private func nameChanged(_ sender: NSTextField) { CloudAccounts.shared.setLabel(accountID, sender.stringValue) }

    @objc private func toggleRow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let root = CloudRoot(rawValue: raw) else { return }
        CloudAccounts.shared.setShows(root, for: accountID, sender.state == .on)
    }
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
