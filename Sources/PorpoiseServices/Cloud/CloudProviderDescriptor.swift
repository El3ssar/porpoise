import Foundation

/// Presentation and navigation policy shared by Connect, Accounts, sidebar, menus and cloud state.
/// Adding a provider changes this service catalog and its backend, never a view's provider switch.
public struct CloudProviderDescriptor: Sendable {
    public struct Root: Sendable {
        public let key: CloudRoot
        public let title: String
        public let icon: String
        public let counted: Bool
    }
    public let provider: CloudProvider
    public let title: String
    public let brand: String
    public let scheme: String?
    public let available: Bool
    public let signInInstructions: String
    public let roots: [Root]
    public let homeURL: URL
    public let accountQuery: String?
    public let supportsTrashUndo: Bool
    /// Two items in one folder may have the same name (Drive); otherwise an existing name is refused, ignoring case.
    public var allowsDuplicateNames = false
    /// The service has documents that live only on the web (Google Docs, Sheets, Slides): exported when copied.
    public var hasWebDocuments = false
    /// Hosts of the service's share links, which the location field hands over before treating text as a path.
    public var linkHosts: Set<String> = []
    /// The service's own page about the account's storage (what the capacity bar opens in its folders).
    public var storageURL: URL?
    /// The path of the root listing what others shared, which shows as Details by when it was shared.
    public var sharedListPath: String?
    /// The Settings fields for the user's own application registration (Settings › Accounts), in order.
    public var configurations: [(key: String, label: String)] {
        switch provider {
        case .googleDrive: return []
        case .dropbox: return [("dropboxAppKey", "Dropbox app key:")]
        case .oneDrive: return [("oneDriveClientID", "OneDrive application (client) ID:")]
        case .box: return [("boxClientID", "Box client ID:"), ("boxClientSecret", "Box client secret:")]
        }
    }
    public func root(_ key: CloudRoot) -> Root { roots.first { $0.key == key } ?? Root(key: key, title: key.title, icon: key.icon, counted: false) }
    public func webLink(_ link: URL, email: String) -> URL {
        guard let accountQuery, var c = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        c.queryItems = (c.queryItems ?? []).filter { $0.name != accountQuery } + [.init(name: accountQuery, value: email)]
        return c.url ?? link
    }
    /// Looked up several times per drawn cloud row: built again only when what it reads changes (the settings store,
    /// the app registrations, test mode). The environment and the app's Info.plist don't change while it runs.
    public static var catalog: [CloudProviderDescriptor] {
        let key = CatalogKey(
            store: ObjectIdentifier(Settings.store), dropbox: Settings.store.string(forKey: "dropboxAppKey"),
            oneDrive: Settings.store.string(forKey: "oneDriveClientID"), box: Settings.store.string(forKey: "boxClientID"),
            boxSecret: Settings.store.object(forKey: "boxClientSecret") != nil, secretRevision: BoxApplicationSecret.revision,
            testing: Settings.isTesting)
        return catalogLock.withLock {
            if let cachedCatalog, cachedCatalog.key == key { return cachedCatalog.catalog }
            let catalog = catalog(dropbox: .selected(), oneDrive: .selected(), box: .selected())
            cachedCatalog = (key, catalog)
            return catalog
        }
    }
    private struct CatalogKey: Equatable {
        var store: ObjectIdentifier
        var dropbox: String?
        var oneDrive: String?
        var box: String?
        var boxSecret: Bool
        var secretRevision: UInt64
        var testing: Bool
    }
    private static let catalogLock = NSLock()
    nonisolated(unsafe) private static var cachedCatalog: (key: CatalogKey, catalog: [CloudProviderDescriptor])?
    public static func catalog(
        dropbox configuration: DropboxConfiguration, oneDrive: OneDriveConfiguration = .selected(), box: BoxConfiguration = .selected()
    ) -> [CloudProviderDescriptor] {
        [
            .init(
                provider: .googleDrive, title: "Google Drive", brand: "google-drive", scheme: "gdrive", available: true,
                signInInstructions:
                    "Sign in to Google and allow Porpoise to see your Drive files. Then come back here. Nothing is typed into Porpoise.",
                roots: [
                    .init(key: .myDrive, title: "My Drive", icon: "folder-cloud", counted: false),
                    .init(key: .sharedWithMe, title: "Shared with me", icon: "folder-publicshare", counted: false),
                    .init(key: .sharedDrives, title: "Shared drives", icon: "folder-network", counted: true),
                ],
                homeURL: URL(string: "https://drive.google.com/drive/my-drive")!, accountQuery: "authuser", supportsTrashUndo: true,
                allowsDuplicateNames: true, hasWebDocuments: true, linkHosts: ["drive.google.com", "docs.google.com"],
                storageURL: URL(string: "https://drive.google.com/settings/storage"), sharedListPath: "/shared-with-me"),
            .init(
                provider: .dropbox, title: "Dropbox", brand: "dropbox", scheme: "dropbox", available: configuration.isConfigured,
                signInInstructions:
                    "Sign in to Dropbox and allow Porpoise to access your files. Then come back here. Nothing is typed into Porpoise.",
                roots: [
                    .init(key: .myDrive, title: "Files", icon: "folder-cloud", counted: false),
                    .init(key: .sharedWithMe, title: "Shared with me", icon: "folder-publicshare", counted: false),
                    .init(key: .sharedDrives, title: "Team space", icon: "folder-network", counted: false),
                ],
                homeURL: URL(string: "https://www.dropbox.com/home")!, accountQuery: nil, supportsTrashUndo: false,
                linkHosts: ["www.dropbox.com", "dropbox.com"], storageURL: URL(string: "https://www.dropbox.com/account/plan"),
                sharedListPath: "/collection:shared"),
            .init(
                provider: .oneDrive, title: "OneDrive", brand: "onedrive", scheme: "onedrive", available: oneDrive.isConfigured,
                signInInstructions:
                    "Sign in to Microsoft and allow Porpoise to access your OneDrive files. Then come back here. Nothing is typed into Porpoise.",
                roots: [
                    .init(key: .myDrive, title: "My files", icon: "folder-cloud", counted: false),
                    .init(key: .sharedWithMe, title: "Shared with me", icon: "folder-publicshare", counted: false),
                ],
                homeURL: URL(string: "https://onedrive.live.com")!, accountQuery: nil, supportsTrashUndo: false,
                linkHosts: ["1drv.ms", "onedrive.live.com"], storageURL: URL(string: "https://onedrive.live.com/?v=managestorage"),
                sharedListPath: "/collection:shared"),
            // Items shared with the person are in All Files once accepted: Box has no separate list of them.
            .init(
                provider: .box, title: "Box", brand: "box", scheme: "box", available: box.isConfigured,
                signInInstructions: "Sign in to Box and allow Porpoise to access your files. Then come back here. Nothing is typed into Porpoise.",
                roots: [.init(key: .myDrive, title: "All Files", icon: "folder-cloud", counted: false)],
                homeURL: URL(string: "https://app.box.com/folder/0")!, accountQuery: nil, supportsTrashUndo: true,
                linkHosts: ["app.box.com", "box.com", "www.box.com"], storageURL: URL(string: "https://app.box.com/account")),
        ]
    }
    /// The service whose share link `text` is (an https link on one of its `linkHosts`).
    public static func linkProvider(_ text: String) -> CloudProviderDescriptor? {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), u.scheme == "https", let host = u.host?.lowercased() else {
            return nil
        }
        return catalog.first { $0.linkHosts.contains(host) }
    }
    public static func descriptor(for url: URL) -> CloudProviderDescriptor? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        return catalog.first { $0.scheme == scheme }
    }
}
extension CloudProvider {
    public var descriptor: CloudProviderDescriptor { CloudProviderDescriptor.catalog.first { $0.provider == self }! }
}
