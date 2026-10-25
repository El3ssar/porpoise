import AppKit
import PorpoiseCore
import PorpoiseServices

/// The Connect sheet (Go › Connect to Server…, ⌘K): one door for cloud accounts and servers. Cloud tiles sign in
/// through the browser and end on a "connected" page in the same sheet; server tiles show the server form.
final class ConnectSheet: SecondaryWindowController {
    /// The sheet on screen, for the test bridge.
    private(set) static var current: ConnectSheet?

    enum Page: Equatable {
        case pick
        case server(ServerKind)
        case waiting(CloudProvider)
        case connected(String)
        case already(String)
        case failed(CloudProvider, String)
    }

    enum ServerKind: String, CaseIterable {
        case sftp, smb, webdav, ftp, s3, other

        var title: String {
            switch self {
            case .sftp: return "SFTP"
            case .smb: return "Windows (SMB)"
            case .webdav: return "WebDAV"
            case .ftp: return "FTP"
            case .s3: return "S3-compatible"
            case .other: return "Other"
            }
        }

        var symbol: String {
            switch self {
            case .sftp: return "terminal"
            case .smb: return "pc"
            case .webdav: return "globe"
            case .ftp: return "arrow.up.arrow.down"
            case .s3: return "cylinder.split.1x2"
            case .other: return "server.rack"
            }
        }

        var isAvailable: Bool { true }
    }

    private(set) var page: Page = .pick
    private weak var parentWindow: NSWindow?
    private let open: (URL) -> Void
    private var cancelSignIn: (() -> Void)?
    /// The browser address of the sign-in in progress ("Open Again").
    private var signInURL: URL?

    /// Shows the sheet on `window`; `open` navigates the window (to My Drive, or a server).
    @discardableResult
    static func run(window: NSWindow?, start: Page = .pick, open: @escaping (URL) -> Void) -> ConnectSheet {
        let s = ConnectSheet(open: open)
        s.parentWindow = window
        s.show(start)
        if let w = window, let sheet = s.window {
            w.beginSheet(sheet)
        } else {
            s.window?.center()
            s.showWindow(nil)
        }
        current = s
        return s
    }

    private init(open: @escaping (URL) -> Void) {
        self.open = open
        let w = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Connect"
        super.init(window: w)
        NotificationCenter.default.addObserver(self, selector: #selector(accountsChanged), name: CloudAccounts.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Pages

    func show(_ p: Page) {
        page = p
        let content: NSView
        switch p {
        case .pick: content = pickPage()
        case .server(let kind): content = serverPage(kind)
        case .waiting(let provider): content = waitingPage(provider)
        case .connected(let id): content = connectedPage(id, already: false)
        case .already(let id): content = connectedPage(id, already: true)
        case .failed(let provider, let message): content = failedPage(provider, message)
        }
        let box = ThemedBackgroundView()
        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The sheet's 20-pt margins (S2).
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: Tokens.Space.xl),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Tokens.Space.xl),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Tokens.Space.xl),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Tokens.Space.xl),
            // Six tiles across, at their full width.
            box.widthAnchor.constraint(equalToConstant: ConnectTile.rowWidth(ServerKind.allCases.count) + 2 * Tokens.Space.xl),
        ])
        window?.contentView = box
        if let window { Theme.dress(window) }
        box.layoutSubtreeIfNeeded()
        window?.setContentSize(box.fittingSize)
    }

    private func pickPage() -> NSView {
        let title = Self.heading("Connect")
        let sub = Self.secondary("Add a cloud account or a server. It appears in the sidebar.")
        // Only what can be added now gets a tile; the rest are named on one quiet line under them.
        let cloud = NSStackView(
            views: CloudProvider.allCases.filter(\.isAvailable).map { p in
                let t = ConnectTile(title: p.title, image: BrandMarks.image(p.brand, size: 30), available: p.isAvailable)
                t.identifier = NSUserInterfaceItemIdentifier("tile-" + p.rawValue)
                t.onClick = { [weak self] in self?.startCloud(p) }
                return t
            })
        cloud.spacing = ConnectTile.spacing
        let later = CloudProvider.allCases.filter { !$0.isAvailable }.map(\.title)
        let more = Self.secondary("More services coming: " + later.joined(separator: ", ") + ".")
        let servers = NSStackView(
            views: ServerKind.allCases.map { k in
                let t = ConnectTile(title: k.title, image: Self.symbol(k.symbol), available: k.isAvailable)
                t.identifier = NSUserInterfaceItemIdentifier("tile-" + k.rawValue)
                t.onClick = { [weak self] in
                    // S3 has keys and an endpoint rather than a server form: it's set up as a saved connection.
                    if k == .s3 { self?.addS3Connection() } else { self?.show(.server(k)) }
                }
                return t
            })
        servers.spacing = ConnectTile.spacing
        let tip = Self.secondary("Tip: you can also paste a server address or a share link in the location bar.")
        let cancel = Self.button("Cancel", self, #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [
            title, sub, Self.caption("CLOUD ACCOUNTS"), cloud, more, Self.caption("SERVERS"), servers, Self.row([tip, NSView(), cancel]),
        ])
        more.isHidden = later.isEmpty
        stack.orientation = .vertical
        stack.alignment = .leading
        // Title and its line, then groups 16 apart, each caption 8 over its tiles; the button row 24 under (D1).
        stack.spacing = Tokens.Space.s
        stack.setCustomSpacing(Tokens.Space.xs, after: title)
        stack.setCustomSpacing(Tokens.Space.l, after: sub)
        stack.setCustomSpacing(later.isEmpty ? Tokens.Space.l : Tokens.Space.xs, after: cloud)
        stack.setCustomSpacing(Tokens.Space.l, after: more)
        stack.setCustomSpacing(Tokens.Space.xxl, after: servers)
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func waitingPage(_ provider: CloudProvider) -> NSView {
        let title = Self.heading(provider.title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let head = NSTextField(labelWithString: "Continue in your browser")
        head.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .semibold)
        let body = Self.secondary(
            provider.descriptor.signInInstructions)
        body.preferredMaxLayoutWidth = 440
        let text = NSStackView(views: [head, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Tokens.Space.xxs
        let info = Self.row([spinner, text])
        info.alignment = .top
        info.spacing = Tokens.Space.m
        let again = Self.linkButton("Browser didn’t open? Open Again", self, #selector(openAgain(_:)))
        let cancel = Self.button("Cancel", self, #selector(cancelWaiting(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [title, info, Self.row([again, NSView(), cancel])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Space.l
        stack.setCustomSpacing(Tokens.Space.xxl, after: info)
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func connectedPage(_ id: String, already: Bool) -> NSView {
        let accounts = CloudAccounts.shared
        guard let a = accounts.account(id) else { return pickPage() }
        let title = Self.heading(already ? "\(a.email) is already connected" : "\(a.provider.title) is connected")
        let card = AccountCard(account: a, avatar: accounts.avatar(id))
        var views: [NSView] = [title, card]
        if !already {
            views.append(Self.secondary("Show in the sidebar:"))
            for root in accounts.availableRows(id) {
                let label = accounts.rootTitle(root, for: id, includeCount: true)
                let check = NSButton(checkboxWithTitle: label, target: self, action: #selector(toggleRow(_:)))
                check.identifier = NSUserInterfaceItemIdentifier(root.rawValue)
                check.state = accounts.shows(root, for: id) ? .on : .off
                views.append(check)
            }
        }
        let close = Self.button("Close", self, #selector(close(_:)))
        close.keyEquivalent = "\u{1b}"
        let primary = Self.button(already ? "Show It" : "Open " + accounts.rootTitle(.myDrive, for: id), self, #selector(openAccount(_:)))
        primary.keyEquivalent = "\r"
        views.append(Self.row([NSView(), close, primary]))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Space.s
        stack.setCustomSpacing(Tokens.Space.m, after: title)
        stack.setCustomSpacing(Tokens.Space.l, after: card)
        if let lastCheck = views.dropLast().last { stack.setCustomSpacing(Tokens.Space.xxl, after: lastCheck) }
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func failedPage(_ provider: CloudProvider, _ message: String) -> NSView {
        let title = Self.heading("Couldn’t connect to \(provider.title)")
        let body = Self.secondary(message)
        body.preferredMaxLayoutWidth = 500
        let back = Self.button("Back", self, #selector(back(_:)))
        back.keyEquivalent = "\u{1b}"
        let retry = Self.button("Try Again", self, #selector(retry(_:)))
        retry.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, body, Self.row([NSView(), back, retry])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Space.m
        stack.setCustomSpacing(Tokens.Space.xxl, after: body)
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: Server form

    private var form: ServerForm?

    private func serverPage(_ kind: ServerKind) -> NSView {
        let f = ServerForm(kind: kind)
        form = f
        let title = Self.heading(kind == .other ? "Connect to a Server" : kind.title)
        let back = Self.button("Back", self, #selector(back(_:)))
        let cancel = Self.button("Cancel", self, #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let connect = Self.button("Connect", self, #selector(connectServer(_:)))
        connect.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, f.view, Self.row([back, NSView(), cancel, connect])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Space.l
        stack.setCustomSpacing(Tokens.Space.xxl, after: f.view)
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(f.server) }
        return stack
    }

    private func addS3Connection() {
        let open = self.open
        finish()
        AccountsServersWindow.show(adding: .s3, open: open)
    }

    static var problemShownForTesting: ((String) -> Void)?

    @objc private func connectServer(_ sender: Any?) {
        guard let form, let url = form.url() else { NSSound.beep(); return }
        if form.addToPlaces {
            // Servers the connection manager knows become saved connections (editable in Accounts & Servers); others a place.
            // A server Accounts & Servers manages is saved there, or the form says what's wrong and stays: it never
            // quietly becomes a plain place that Accounts & Servers can't list or edit.
            if let (_, problem) = form.draftProfile(), let problem {
                let alert = NSAlert()
                alert.messageText = "Connection wasn’t saved."
                alert.informativeText = problem
                if let window { alert.beginSheetModal(for: window) }
                Self.problemShownForTesting?(problem)
                return
            }
            if let profile = form.profile() {
                do { try ConnectionProfiles.shared.save(profile).get() } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Connection wasn’t saved."
                    if let window { alert.beginSheetModal(for: window) }
                    return
                }
            } else {
                PlacesModel.shared.add(url, title: form.name)
            }
        }
        finish()
        open(url)
    }

    // MARK: Cloud sign-in

    private func startCloud(_ provider: CloudProvider) {
        show(.waiting(provider))
        cancelSignIn = CloudAccounts.shared.connect(
            provider,
            openBrowser: { [weak self] url in
                self?.signInURL = url
                Self.openBrowser(url)
            },
            done: { [weak self] result in
                guard let self, case .waiting = self.page else { return }
                self.cancelSignIn = nil
                // Signed in in the browser: back to Porpoise, where the sheet shows the account.
                if case .success = result { NSApp.activate() }
                if case .failure(.alreadyConnected) = result { NSApp.activate() }
                switch result {
                case .success(let a): self.show(.connected(a.id))
                case .failure(.alreadyConnected(let a)): self.show(.already(a.id))
                // Closing the browser isn't a failure: back to the tiles, no alert.
                case .failure(.cancelled): self.show(.pick)
                case .failure(.failed(let message)): self.show(.failed(provider, message))
                }
            })
    }

    @objc private func openAgain(_ sender: Any?) {
        if let u = signInURL { Self.openBrowser(u) }
    }

    @objc private func cancelWaiting(_ sender: Any?) {
        cancelSignIn?()
        cancelSignIn = nil
        show(.pick)
    }

    @objc private func retry(_ sender: Any?) {
        if case .failed(let p, _) = page { startCloud(p) }
    }

    @objc private func back(_ sender: Any?) { show(.pick) }

    @objc private func toggleRow(_ sender: NSButton) {
        guard case .connected(let id) = page, let raw = sender.identifier?.rawValue, let root = CloudRoot(rawValue: raw) else { return }
        CloudAccounts.shared.setShows(root, for: id, sender.state == .on)
    }

    @objc private func openAccount(_ sender: Any?) {
        let id: String
        switch page {
        case .connected(let i), .already(let i): id = i
        default: return
        }
        let accounts = CloudAccounts.shared
        let root = accounts.availableRows(id).first { accounts.shows($0, for: id) } ?? .myDrive
        finish()
        if let u = accounts.url(id, root: root) { open(u) }
    }

    @objc private func accountsChanged() {
        // The avatar or quota arrived after the page was built.
        switch page {
        case .connected, .already: show(page)
        default: break
        }
    }

    @objc func close(_ sender: Any?) {
        cancelSignIn?()
        cancelSignIn = nil
        finish()
    }

    private func finish() {
        guard let sheet = window else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        if Self.current === self { Self.current = nil }
    }

    /// The sign-in page, in the user's browser. Test instances against the fake Drive server can have it fetched
    /// instead (PORPOISE_CLOUD_BROWSER=fetch), which follows the same redirect back without opening a browser tab.
    static func openBrowser(_ url: URL) {
        if Settings.isTesting, TestEnvironment.cloudBrowser.value() == "fetch" {
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Building blocks

    static func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: Tokens.FontSize.title3, weight: .semibold)
        return t
    }

    static func secondary(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: Tokens.FontSize.callout)
        t.textColor = .secondaryLabelColor
        return t
    }

    static func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: Tokens.FontSize.caption, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        return t
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .push
        return b
    }

    static func linkButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .linkColor
        b.font = .systemFont(ofSize: Tokens.FontSize.callout)
        return b
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Tokens.Space.s
        return r
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
    }
}

/// One choice on the Connect sheet: a mark and a name; unavailable ones say "Coming soon".
final class ConnectTile: NSControl {
    var onClick: (() -> Void)?
    private let title: String
    private let image: NSImage?
    private let available: Bool
    private var hovering = false
    private var pressing = false
    /// Wide enough for the longest name ("S3-compatible", "Windows (SMB)") on one line.
    static let size = CGSize(width: 100, height: 78)
    static let spacing = Tokens.Space.s
    static let titleFont = NSFont.systemFont(ofSize: Tokens.FontSize.small, weight: .medium)
    static func rowWidth(_ count: Int) -> CGFloat { CGFloat(count) * size.width + CGFloat(max(count - 1, 0)) * spacing }

    init(title: String, image: NSImage?, available: Bool) {
        self.title = title
        self.image = image
        self.available = available
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        toolTip = available ? nil : "\(title) is coming in a later version."
        setAccessibilityRole(.button)
        setAccessibilityLabel(available ? title : "\(title), coming soon")
        setAccessibilityEnabled(available)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard available else { return }
        pressing = true
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        needsDisplay = true
        if available, inside { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard available else { return false }
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        let base: CGFloat = pressing ? 0.16 : (hovering && available ? 0.11 : 0.06)
        Theme.windowText.withAlphaComponent(base).setFill()
        path.fill()
        Theme.windowText.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
        let alpha: CGFloat = available ? 1 : 0.4
        if let image {
            let s: CGFloat = 30
            let img = image.isTemplate ? Self.tinted(image) : image
            let w = min(s, img.size.width * s / max(img.size.height, 1))
            img.draw(
                in: CGRect(x: r.midX - w / 2, y: 12, width: w, height: s), from: .zero, operation: .sourceOver, fraction: alpha,
                respectFlipped: true, hints: nil)
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont, .foregroundColor: Theme.windowText.withAlphaComponent(alpha * 0.9),
            .paragraphStyle: p,
        ]
        (title as NSString).draw(in: CGRect(x: 4, y: 48, width: r.width - 8, height: 15), withAttributes: attrs)
        if !available {
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Tokens.FontSize.caption), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: p,
            ]
            ("Coming soon" as NSString).draw(in: CGRect(x: 4, y: 62, width: r.width - 8, height: 12), withAttributes: small)
        }
    }

    /// SF Symbols are templates: drawn in the label colour.
    private static func tinted(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            Theme.windowText.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

/// The account's picture, name, email and storage, as on the "connected" page and in Settings › Accounts.
final class AccountCard: NSView {
    init(account a: CloudAccount, avatar: Data?, avatarSize: CGFloat = 36) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.windowText.withAlphaComponent(0.05).cgColor
        let pic = NSImageView(image: BrandMarks.avatar(avatar, name: a.displayName, email: a.email, size: avatarSize))
        pic.widthAnchor.constraint(equalToConstant: avatarSize).isActive = true
        pic.heightAnchor.constraint(equalToConstant: avatarSize).isActive = true
        let name = NSTextField(labelWithString: a.displayName.isEmpty ? a.email : a.displayName)
        name.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .semibold)
        var lines: [NSView] = [name]
        if !a.displayName.isEmpty { lines.append(ConnectSheet.secondary(a.email)) }
        if let quota = QuotaBar.make(used: a.quotaUsed, total: a.quotaTotal) { lines.append(quota) }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Tokens.Space.xxs
        let row = NSStackView(views: [pic, text])
        row.alignment = .centerY
        row.spacing = Tokens.Space.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Tokens.Space.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Tokens.Space.m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.Space.m),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Tokens.Space.m),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.windowText.withAlphaComponent(0.05).cgColor
        }
    }
}

/// "4.1 GB of 15 GB used" with a capacity bar.
enum QuotaBar {
    static func make(used: Int64?, total: Int64?) -> NSView? {
        guard let used else { return nil }
        let label = ConnectSheet.secondary(text(used: used, total: total))
        guard let total, total > 0 else { return label }
        let bar = CapacityBarView(fraction: StorageCapacity(used: used, total: total).fraction)
        bar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let v = NSStackView(views: [bar, label])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = Tokens.Space.xs
        return v
    }

    static func text(used: Int64, total: Int64?) -> String {
        guard let total, total > 0 else { return "\(FileFormat.size(used)) used" }
        return "\(FileFormat.size(used)) of \(FileFormat.size(total)) used"
    }
}

/// The server fields: the tile is the type, so there's no Type popup (except under Other).
final class ServerForm {
    let kind: ConnectSheet.ServerKind
    let view = NSGridView()
    let server = NSTextField()
    private let nameField = NSTextField()
    let port = NSTextField()
    private let user = NSTextField()
    private let folder = NSTextField()
    private let secure: NSButton?
    private let otherType: NSPopUpButton?
    private let add = NSButton(checkboxWithTitle: "Add to Places", target: nil, action: nil)

    /// Under Other: what the type popup offers.
    static let otherKinds: [(title: String, scheme: String, port: Int)] = [
        ("NFS", "nfs", 2049), ("Apple file server (AFP)", "afp", 548),
    ]

    init(kind: ConnectSheet.ServerKind) {
        self.kind = kind
        switch kind {
        case .webdav: secure = NSButton(checkboxWithTitle: "Secure connection (HTTPS)", target: nil, action: nil)
        case .ftp: secure = NSButton(checkboxWithTitle: "Encrypt with TLS (FTPS)", target: nil, action: nil)
        default: secure = nil
        }
        secure?.state = kind == .webdav ? .on : .off
        if kind == .other {
            let p = NSPopUpButton()
            p.addItems(withTitles: Self.otherKinds.map(\.title))
            otherType = p
        } else {
            otherType = nil
        }
        add.state = .on
        nameField.placeholderString = "My server"
        server.placeholderString = "example.com or 192.168.1.10"
        port.placeholderString = String(defaultPort)
        user.placeholderString = NSUserName()
        folder.placeholderString = kind == .smb ? "Share name" : "/home/me"
        var rows: [[NSView]] = []
        if let otherType { rows.append([Self.label("Type:"), otherType]) }
        rows += [
            [Self.label("Server:"), server], [Self.label("Port:"), port], [Self.label("User:"), user],
            [Self.label(kind == .smb ? "Share:" : "Folder:"), folder], [Self.label("Name:"), nameField],
        ]
        if let secure { rows.append([NSGridCell.emptyContentView, secure]) }
        rows.append([NSGridCell.emptyContentView, add])
        for r in rows { view.addRow(with: r) }
        view.column(at: 0).xPlacement = .trailing
        // The labels keep their width; the fields take the rest, so the form sits under the title.
        view.column(at: 0).width = 90
        view.rowAlignment = .firstBaseline
        view.columnSpacing = Tokens.Space.s
        view.rowSpacing = Tokens.Space.s
        for f in [server, nameField, port, user, folder] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
    }

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    var name: String? { nameField.stringValue.isEmpty ? nil : nameField.stringValue }
    var addToPlaces: Bool { add.state == .on }

    var scheme: String {
        let on = secure?.state == .on
        switch kind {
        case .sftp: return "sftp"
        case .smb: return "smb"
        case .webdav: return on ? "webdavs" : "webdav"
        case .ftp: return on ? "ftps" : "ftp"
        case .s3: return "s3"
        case .other: return Self.otherKinds[otherType?.indexOfSelectedItem ?? 0].scheme
        }
    }

    var defaultPort: Int {
        switch scheme {
        case "sftp": return 22
        case "smb": return 445
        case "webdav": return 80
        case "webdavs": return 443
        case "ftp", "ftps": return 21
        default: return Self.otherKinds.first { $0.scheme == scheme }?.port ?? 0
        }
    }

    /// The fields as a saved connection, for the kinds the Accounts & Servers window manages.
    func profile() -> ConnectionProfile? {
        guard let (p, problem) = draftProfile(), problem == nil else { return nil }
        return p
    }

    /// The saved connection the fields describe and what's wrong with it, for the kinds Accounts & Servers manages (nil
    /// for others, which become a plain place).
    func draftProfile() -> (ConnectionProfile, problem: String?)? {
        let kind: ConnectionProfile.Kind
        switch scheme {
        case "sftp": kind = .sftp
        case "ftp": kind = .ftp
        case "ftps": kind = .ftps
        case "smb": kind = .smb
        default: return nil
        }
        let host = server.stringValue.trimmingCharacters(in: .whitespaces)
        let u = user.stringValue.trimmingCharacters(in: .whitespaces)
        let p = ConnectionProfile(
            name: name ?? host, kind: kind, host: host, port: Int(port.stringValue).flatMap { $0 == defaultPort ? nil : $0 },
            user: u.isEmpty ? nil : u, path: folder.stringValue.trimmingCharacters(in: .whitespaces))
        return (p, p.problem)
    }

    /// The address the fields describe (nil without a server).
    func url() -> URL? {
        let host = server.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        if let p = Int(port.stringValue), p != defaultPort { c.port = p }
        if !user.stringValue.isEmpty { c.user = user.stringValue }
        var path = folder.stringValue.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty && !path.hasPrefix("/") { path = (scheme == "sftp" ? "/~/" : "/") + path }
        c.path = path.isEmpty ? "/" : path
        return c.url
    }
}
