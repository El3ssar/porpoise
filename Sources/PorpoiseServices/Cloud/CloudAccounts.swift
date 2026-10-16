import Foundation
import PorpoiseCore

/// Cloud storage services Porpoise can connect to. Only Google Drive works so far; the others are shown on the
/// Connect sheet as coming later.
public enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case googleDrive, dropbox, oneDrive, box

    public var title: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        case .box: return "Box"
        }
    }

    /// The mark's file name in Resources/brands.
    public var brand: String {
        switch self {
        case .googleDrive: return "google-drive"
        case .dropbox: return "dropbox"
        case .oneDrive: return "onedrive"
        case .box: return "box"
        }
    }

    public var isAvailable: Bool { self == .googleDrive }
}

/// The rows an account shows in the sidebar.
public enum CloudRoot: String, Codable, CaseIterable, Sendable {
    case myDrive, sharedWithMe, sharedDrives

    public var title: String {
        switch self {
        case .myDrive: return "My Drive"
        case .sharedWithMe: return "Shared with me"
        case .sharedDrives: return "Shared drives"
        }
    }

    /// Icon theme name for the sidebar row.
    public var icon: String {
        switch self {
        case .myDrive: return "folder-cloud"
        case .sharedWithMe: return "folder-publicshare"
        case .sharedDrives: return "folder-network"
        }
    }
}

/// A connected account, as the backend reports it.
public struct CloudAccount: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case ok, offline, signInNeeded }
    public var id: String
    public var provider: CloudProvider
    public var email: String
    public var displayName: String
    public var photoURL: URL?
    public var quotaUsed: Int64?
    /// nil: unlimited or unknown.
    public var quotaTotal: Int64?
    /// Number of shared drives the account can see (the row is offered only when there are some).
    public var sharedDriveCount: Int
    public var status: Status
    /// The sign-in allows changes (false: an account connected when Porpoise could only read).
    public var canWrite: Bool

    public init(
        id: String, provider: CloudProvider = .googleDrive, email: String, displayName: String, photoURL: URL? = nil,
        quotaUsed: Int64? = nil, quotaTotal: Int64? = nil, sharedDriveCount: Int = 0, status: Status = .ok, canWrite: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.quotaUsed = quotaUsed
        self.quotaTotal = quotaTotal
        self.sharedDriveCount = sharedDriveCount
        self.status = status
        self.canWrite = canWrite
    }
}

public enum CloudConnectError: Error, Equatable {
    /// The user closed the browser or pressed Cancel: not an error to show.
    case cancelled
    case alreadyConnected(CloudAccount)
    case failed(String)
}

/// What Properties and the browser's columns show about a cloud item.
public struct CloudItemInfo: Equatable, Sendable {
    public enum Access: String, Sendable { case owner = "Owner", editor = "Editor", commenter = "Commenter", viewer = "Viewer" }
    public var ownerName: String?
    public var ownerEmail: String?
    public var access: Access?
    /// People it's shared with, besides the owner (nil: unknown, e.g. not visible to viewers).
    public var sharedWithCount: Int?
    /// The first few names, for the tooltip.
    public var sharedWithNames: [String]
    /// "can view" / "can comment" / "can edit" when anyone with the link has access.
    public var anyoneWithLink: String?
    public var modifiedBy: String?
    public var sharedBy: String?
    public var webLink: URL?
    /// A Google Doc, Sheet, Slides…: opens in the browser and copies out as an export.
    public var isWebDocument: Bool
    /// "Google Sheets spreadsheet".
    public var kind: String?
    public var name: String?
    public var isFolder: Bool

    public init(
        ownerName: String? = nil, ownerEmail: String? = nil, access: Access? = nil, sharedWithCount: Int? = nil,
        sharedWithNames: [String] = [], anyoneWithLink: String? = nil, modifiedBy: String? = nil, sharedBy: String? = nil,
        webLink: URL? = nil, isWebDocument: Bool = false, kind: String? = nil, name: String? = nil, isFolder: Bool = false
    ) {
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.access = access
        self.sharedWithCount = sharedWithCount
        self.sharedWithNames = sharedWithNames
        self.anyoneWithLink = anyoneWithLink
        self.modifiedBy = modifiedBy
        self.sharedBy = sharedBy
        self.webLink = webLink
        self.isWebDocument = isWebDocument
        self.kind = kind
        self.name = name
        self.isFolder = isFolder
    }

    /// "4 people and anyone with the link (can view)".
    public var sharingSummary: String? {
        var parts: [String] = []
        if let n = sharedWithCount, n > 0 { parts.append(n == 1 ? "1 person" : "\(n) people") }
        if let l = anyoneWithLink { parts.append("anyone with the link (\(l))") }
        if parts.isEmpty { return sharedWithCount == 0 ? "Only the owner" : nil }
        return parts.joined(separator: " and ")
    }
}

/// What a pasted Drive link turned into.
public enum CloudLinkResult: Equatable {
    case folder(URL)
    /// A file: opened in the browser (Google Docs) or downloaded.
    case file(URL)
    /// No connected account can open it.
    case noAccess
    case notALink
}

/// The service behind the accounts (Google Drive's account store; a demo one in test instances). Calls back on the
/// main queue.
public protocol CloudBackend: AnyObject {
    var accounts: [CloudAccount] { get }
    /// Set by `CloudAccounts`; called on the main queue whenever accounts, their status or quota change.
    var onChange: (() -> Void)? { get set }
    /// Signs in through the browser; returns a cancel function. Cancelling leaves nothing behind.
    func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void
    /// Only the browser step, for an expired or revoked sign-in.
    func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void) -> () -> Void
    /// Signs out: forgets the credentials and the cache.
    func remove(_ id: String, done: @escaping (Error?) -> Void)
    /// The location of one of an account's rows.
    func url(_ id: String, root: CloudRoot) -> URL
    /// The account a location belongs to.
    func accountID(for url: URL) -> String?
    func info(for url: URL) -> CloudItemInfo?
    func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void)
    /// The account picture's bytes (nil: none).
    func avatar(_ id: String, done: @escaping (Data?) -> Void)

    // Changes (CloudEditing.swift has the defaults: nothing can be changed).
    /// What can be done with an item or folder; nil: not known yet.
    func permissions(for url: URL) -> CloudPermissions?
    /// Only the browser step, asking for permission to make changes.
    func requestWriteAccess(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void)
    func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void)
    /// Moves items to the service's own trash, never deleting them; `trashed` are those that went.
    func trash(_ urls: [URL], done: @escaping (_ trashed: [URL], _ error: Error?) -> Void)
    func untrash(_ urls: [URL], done: @escaping (_ restored: [URL], _ error: Error?) -> Void)
}

/// Connected cloud accounts as the app shows them: labels, which rows each shows in the sidebar, avatars, and the
/// sidebar sections built from them.
public final class CloudAccounts {
    public static let shared = CloudAccounts()
    public static let changed = Notification.Name("PorpoiseCloudAccountsChanged")

    public var backend: CloudBackend? {
        didSet {
            backend?.onChange = { [weak self] in self?.backendChanged() }
            backendChanged()
        }
    }

    public var accounts: [CloudAccount] { backend?.accounts ?? [] }

    public func account(_ id: String) -> CloudAccount? { accounts.first { $0.id == id } }

    /// The account a location belongs to.
    public func account(for url: URL) -> CloudAccount? {
        guard PlacesModel.isCloud(url), let id = backend?.accountID(for: url) else { return nil }
        return account(id)
    }

    // MARK: Per-account choices

    private struct Prefs: Codable, Equatable {
        var label: String?
        var hiddenRows: [CloudRoot] = []
    }
    private static let prefsKey = "cloudAccounts"
    private var prefs: [String: Prefs] {
        get {
            guard let d = Settings.store.data(forKey: Self.prefsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Prefs].self, from: d)) ?? [:]
        }
        set {
            Settings.store.set(try? JSONEncoder().encode(newValue), forKey: Self.prefsKey)
            publish()
        }
    }

    /// The name the user gave the account (shown after the provider when there are several accounts of it).
    public func label(_ id: String) -> String { prefs[id]?.label ?? defaultLabel(id) }

    public func setLabel(_ id: String, _ label: String) {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs[id, default: Prefs()].label = t.isEmpty || t == defaultLabel(id) ? nil : t
    }

    /// The email's domain for work accounts, its local part for personal addresses.
    func defaultLabel(_ id: String) -> String {
        guard let email = account(id)?.email, let at = email.lastIndex(of: "@") else { return "" }
        let domain = String(email[email.index(after: at)...]).lowercased()
        let personal: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com"]
        return personal.contains(domain) ? String(email[..<at]) : domain
    }

    /// Section header and breadcrumb root: "Google Drive", or "Google Drive · work" when the provider has two accounts.
    public func title(_ id: String) -> String {
        guard let a = account(id) else { return "" }
        let siblings = accounts.filter { $0.provider == a.provider }.count
        return siblings > 1 ? "\(a.provider.title) · \(label(id))" : a.provider.title
    }

    /// The rows the account offers: Shared drives only when it has some.
    public func availableRows(_ id: String) -> [CloudRoot] {
        CloudRoot.allCases.filter { $0 != .sharedDrives || (account(id)?.sharedDriveCount ?? 0) > 0 }
    }

    public func shows(_ root: CloudRoot, for id: String) -> Bool { !(prefs[id]?.hiddenRows.contains(root) ?? false) }

    public func setShows(_ root: CloudRoot, for id: String, _ on: Bool) {
        var p = prefs[id, default: Prefs()]
        p.hiddenRows.removeAll { $0 == root }
        if !on { p.hiddenRows.append(root) }
        prefs[id] = p
    }

    /// App-wide: what Google Docs become when copied out of Drive. Shared with the Drive service.
    public static let exportPresetKey = "googleDriveExportPreset"
    public static let exportPresets: [(key: String, title: String)] = [
        ("office", "Microsoft Office (.docx, .xlsx, .pptx)"), ("pdf", "PDF"), ("openDocument", "OpenDocument (.odt, .ods, .odp)"),
    ]
    public var exportPreset: String {
        get { Settings.store.string(forKey: Self.exportPresetKey) ?? "office" }
        set {
            Settings.store.set(newValue, forKey: Self.exportPresetKey)
            NotificationCenter.default.post(name: Settings.changed, object: Self.exportPresetKey)
        }
    }

    // MARK: Avatars

    private var avatars: [String: Data] = [:]
    private var avatarRequests: Set<String> = []

    /// The account's picture, once fetched (nil until then, or when there is none).
    public func avatar(_ id: String) -> Data? {
        if let d = avatars[id] { return d }
        if avatarRequests.insert(id).inserted, let backend {
            var answered = false
            backend.avatar(id) { [weak self] data in
                answered = true
                guard let self, let data else { return }
                self.avatars[id] = data
                // A cached picture answers at once, while the sidebar is being built: show it in the next pass.
                DispatchQueue.main.async { self.publish() }
            }
            if answered { return avatars[id] }
        }
        return nil
    }

    // MARK: Actions

    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        guard let backend, provider.isAvailable else {
            done(.failure(.failed("\(provider.title) isn’t available yet.")))
            return {}
        }
        return backend.connect(provider, openBrowser: openBrowser, done: done)
    }

    public func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    {
        guard let backend else { done(.failure(.failed("Not connected."))); return {} }
        return backend.signInAgain(id, openBrowser: openBrowser, done: done)
    }

    /// Places that point into the account (listed before removing it).
    public func places(of id: String) -> [PlaceEntry] {
        PlacesModel.shared.userEntries.filter { account(for: $0.url)?.id == id }
    }

    public func remove(_ id: String, done: @escaping (Error?) -> Void) {
        guard let backend else { done(nil); return }
        backend.remove(id) { [weak self] error in
            var p = self?.prefs ?? [:]
            p[id] = nil
            self?.prefs = p
            self?.avatars[id] = nil
            self?.avatarRequests.remove(id)
            done(error)
        }
    }

    public func url(_ id: String, root: CloudRoot) -> URL? { backend?.url(id, root: root) }

    public func info(for url: URL) -> CloudItemInfo? { backend?.info(for: url) }

    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {
        guard Self.looksLikeLink(text), let backend else { done(.notALink); return }
        backend.resolveLink(text, done: done)
    }

    /// drive.google.com and docs.google.com links (what the location field hands over before treating text as a path).
    public static func looksLikeLink(_ text: String) -> Bool {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), u.scheme == "https", let host = u.host?.lowercased() else {
            return false
        }
        return host == "drive.google.com" || host == "docs.google.com"
    }

    // MARK: Sidebar

    /// One sidebar section per account, rows as chosen; My Drive carries the quota bar.
    public func sections() -> [AccountSection] {
        accounts.map { a in
            let rows = availableRows(a.id).filter { shows($0, for: a.id) }
            let entries = rows.compactMap { root -> PlaceEntry? in
                guard let u = url(a.id, root: root) else { return nil }
                return PlaceEntry(
                    title: root.title, url: u, icon: root.icon, section: .account(a.id),
                    isVolume: root == .myDrive && a.quotaTotal != nil)
            }
            let status: AccountSection.Status
            switch a.status {
            case .ok: status = .ok
            case .offline: status = .offline
            case .signInNeeded: status = .signInNeeded
            }
            // The header has the provider's mark: with several accounts, their names tell them apart.
            let several = accounts.filter { $0.provider == a.provider }.count > 1
            return AccountSection(
                id: a.id, title: several ? label(a.id) : a.provider.title, email: a.email, displayName: a.displayName, avatar: avatar(a.id),
                brand: a.provider.brand,
                status: status, entries: entries, quotaUsed: a.quotaUsed, quotaTotal: a.quotaTotal)
        }
    }

    private func backendChanged() {
        let live = Set(accounts.map(\.id))
        avatarRequests = avatarRequests.intersection(live)
        publish()
    }

    private func publish() {
        PlacesModel.shared.accounts = sections()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
