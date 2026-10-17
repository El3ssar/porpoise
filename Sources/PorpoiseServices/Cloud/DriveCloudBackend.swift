import Combine
import Foundation
import PorpoiseCore

/// Google Drive accounts (DriveAccountStore) as the app's cloud accounts: adds what the screens need on top, the
/// quota, the shared drives, a cached picture, sharing details and pasted links.
public final class DriveCloudBackend: CloudBackend {
    public var onChange: (() -> Void)?
    let store: DriveAccountStore
    var quotaRefresh: CloudQuotaRefresh?
    private var watch: AnyCancellable?
    /// Quota and shared drives per account, refreshed at launch, on reload and while active.
    private var details: [UUID: (used: Int64?, total: Int64?, drives: Int)] = [:]
    private var fetching: Set<UUID> = []
    /// Where account pictures are kept between launches.
    private let avatarFolder: URL

    @MainActor
    public init(store: DriveAccountStore, avatarFolder: URL? = nil) {
        self.store = store
        self.avatarFolder = avatarFolder ?? Settings.cachesFolder.appendingPathComponent("avatars")
        quotaRefresh = CloudQuotaRefresh { [weak self] in self?.refreshQuotas() }
        watch = store.objectWillChange.sink { [weak self] _ in
            // Published values change after this fires.
            DispatchQueue.main.async { self?.storeChanged() }
        }
        // Accounts restored at launch: their quota and shared drives.
        DispatchQueue.main.async { [weak self] in self?.storeChanged() }
    }

    private func storeChanged() {
        MainActor.assumeIsolated {
            for a in store.accounts where details[a.id] == nil { fetchDetails(a.id) }
        }
        onChange?()
    }

    public var accounts: [CloudAccount] {
        MainActor.assumeIsolated {
            store.accounts.map { a in
                let d = details[a.id]
                let status: CloudAccount.Status
                switch store.states[a.id] {
                case .offline: status = .offline
                case .needsSignIn: status = .signInNeeded
                default: status = .ok
                }
                return CloudAccount(
                    id: Self.key(a.id), email: a.email, displayName: a.displayName, photoURL: a.photoURL, quotaUsed: d?.used,
                    quotaTotal: d?.total, sharedDriveCount: d?.drives ?? 0, status: status,
                    // Unknown until the grant is checked: assume yes, so "Allow Changes" never flashes at launch.
                    canWrite: store.writeAccess[a.id] != false)
            }
        }
    }

    /// Account ids as they appear in locations (lowercased, like the URL's host).
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func uuid(_ key: String) -> UUID? { UUID(uuidString: key) }

    private func account(_ key: String) -> DriveAccount? {
        guard let id = uuid(key) else { return nil }
        return MainActor.assumeIsolated { store.accounts.first { $0.id == id } }
    }

    @MainActor func refreshQuotas(_ id: String? = nil) {
        for account in store.accounts where id == nil || Self.key(account.id) == id { fetchDetails(account.id) }
    }

    @MainActor private func fetchDetails(_ id: UUID) {
        guard let client = store.client(for: id), fetching.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.fetching.remove(id) }
            guard let info = try? await client.accountInfo() else { return }
            let drives = info.hasSharedDrives ? ((try? await client.list(DriveLocation(accountID: id, collection: .sharedDrives)).count) ?? 1) : 0
            guard self?.store.client(for: id) === client else { return }
            self?.details[id] = (info.storageUsed, info.storageLimit, drives)
            self?.onChange?()
        }
    }

    // MARK: Sign-in

    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let a = try await self.store.connect(openBrowser: { openBrowser($0) })
                self.fetchDetails(a.id)
                done(
                    .success(
                        self.accounts.first { $0.id == Self.key(a.id) }
                            ?? CloudAccount(id: Self.key(a.id), email: a.email, displayName: a.displayName)))
            } catch {
                done(.failure(self.connectError(error)))
            }
        }
        return { task.cancel() }
    }

    private func connectError(_ error: Error) -> CloudConnectError {
        if error is CancellationError || (error as? DriveError) == .oauthCancelled { return .cancelled }
        if case .alreadyConnected(let a) = error as? DriveConnectionError {
            return .alreadyConnected(
                accounts.first { $0.id == Self.key(a.id) } ?? CloudAccount(id: Self.key(a.id), email: a.email, displayName: a.displayName))
        }
        return .failed(error.localizedDescription)
    }

    public func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    {
        guard let a = account(id) else { done(.failure(.failed("This account is no longer connected."))); return {} }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.store.reauthorize(a, openBrowser: { openBrowser($0) })
                done(.success(()))
            } catch {
                done(.failure(self.connectError(error)))
            }
        }
        return { task.cancel() }
    }

    public func remove(_ id: String, done: @escaping (Error?) -> Void) {
        guard let a = account(id) else { done(nil); return }
        try? FileManager.default.removeItem(at: avatarFile(id))
        Task { @MainActor [weak self] in
            var failure: Error?
            do { try await self?.store.disconnect(a) } catch { failure = error }
            self?.details[a.id] = nil
            done(failure)
        }
    }

    // MARK: Locations

    public func url(_ id: String, root: CloudRoot) -> URL {
        let collection: DriveLocation.Collection
        switch root {
        case .myDrive: collection = .myDrive
        case .sharedWithMe: collection = .sharedWithMe
        case .sharedDrives: collection = .sharedDrives
        }
        return DriveLocation(accountID: uuid(id) ?? UUID(), collection: collection).url
    }

    public func accountID(for url: URL) -> String? { DriveLocation(url: url).map { Self.key($0.accountID) } }

    public func info(for url: URL) -> CloudItemInfo? {
        guard let location = DriveLocation(url: url), let file = (RemoteFS.provider(for: url) as? DriveProvider)?.metadata(for: url) else {
            return nil
        }
        let me = MainActor.assumeIsolated { store.accounts.first { $0.id == location.accountID }?.email.lowercased() }
        return Self.info(file, me: me)
    }

    /// What the screens show about a Drive item, from its metadata. `me`: the account's email.
    static func info(_ file: DriveFile, me: String?) -> CloudItemInfo {
        let owner = file.owners?.first
        let permissions = file.permissions ?? []
        let people = permissions.filter { $0.type != "anyone" && $0.role != "owner" }
        let anyone = permissions.first { $0.type == "anyone" }
        var access: CloudItemInfo.Access?
        if let me, owner?.emailAddress?.lowercased() == me {
            access = .owner
        } else if let role = permissions.first(where: { $0.emailAddress?.lowercased() == me && me != nil })?.role ?? anyone?.role {
            access = Self.access(role)
        }
        return CloudItemInfo(
            ownerName: owner?.displayName, ownerEmail: owner?.emailAddress, access: access,
            sharedWithCount: file.permissions == nil ? nil : people.count,
            sharedWithNames: people.prefix(3).compactMap { $0.displayName ?? $0.emailAddress },
            anyoneWithLink: anyone.map { "can " + (Self.access($0.role).map(Self.verb) ?? "view") },
            modifiedBy: file.lastModifyingUser?.displayName, sharedBy: file.sharingUser?.displayName,
            webLink: file.webViewLink ?? (file.isFolder ? URL(string: "https://drive.google.com/drive/folders/\(file.id)") : nil),
            isWebDocument: file.isGoogleDocument, kind: Self.kind(file.mimeType), name: file.name, isFolder: file.isFolder)
    }

    static func access(_ role: String?) -> CloudItemInfo.Access? {
        switch role {
        case "owner": return .owner
        case "organizer", "fileOrganizer", "writer": return .editor
        case "commenter": return .commenter
        case "reader": return .viewer
        default: return nil
        }
    }

    private static func verb(_ a: CloudItemInfo.Access) -> String {
        switch a {
        case .owner, .editor: return "edit"
        case .commenter: return "comment"
        case .viewer: return "view"
        }
    }

    /// "Google Sheets spreadsheet" for Google's own types; nil for ordinary files (their type says it).
    static func kind(_ mimeType: String) -> String? {
        switch mimeType.replacingOccurrences(of: "application/vnd.google-apps.", with: "") {
        case "document": return "Google Docs document"
        case "spreadsheet": return "Google Sheets spreadsheet"
        case "presentation": return "Google Slides presentation"
        case "form": return "Google Forms form"
        case "drawing": return "Google Drawings drawing"
        case "site": return "Google Sites site"
        case "jam": return "Jamboard"
        case "map": return "Google My Maps map"
        default: return nil
        }
    }

    /// Tries each account until one can see the item.
    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), let link = DriveLink(url: u) else { done(.notALink); return }
        let ids = MainActor.assumeIsolated { store.accounts.map(\.id) }
        Task { @MainActor [weak self] in
            for id in ids {
                guard let client = self?.store.client(for: id), let file = try? await client.file(link.itemID, resourceKey: link.resourceKey)
                else { continue }
                let location = file.location(accountID: id)
                done(file.isFolder ? .folder(location.url) : .file(file.webViewLink ?? location.url))
                return
            }
            done(.noAccess)
        }
    }

    // MARK: Pictures

    private func avatarFile(_ id: String) -> URL { avatarFolder.appendingPathComponent(id + ".img") }

    /// The cached picture, else downloaded once (https only) and kept.
    public func avatar(_ id: String, done: @escaping (Data?) -> Void) {
        if let d = try? Data(contentsOf: avatarFile(id)) { done(d); return }
        guard let photo = account(id)?.photoURL, photo.scheme == "https" else { done(nil); return }
        let file = avatarFile(id), folder = avatarFolder
        URLSession.shared.dataTask(with: photo) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let picture = ok ? data : nil
            if let picture {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? picture.write(to: file)
            }
            DispatchQueue.main.async { done(picture) }
        }.resume()
    }
}
