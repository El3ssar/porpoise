import Foundation
import PorpoiseCore

/// Dropbox policy behind the same account/edit/search/offline contracts the UI uses for every provider.
public final class DropboxCloudBackend: CloudBackend {
    public var onChange: (() -> Void)?
    public let store: DropboxAccountStore
    private var quotas: [UUID: DropboxSpaceUsage] = [:]
    private var fetchingQuota: Set<UUID> = []
    private var quotaRefresh: CloudQuotaRefresh?
    private var providers: [UUID: DropboxProvider] = [:]
    /// Folders above a location being read once (by account, namespace and path), so drawing doesn't ask again.
    private var ancestorFetches: Set<String> = []
    @MainActor public init(store: DropboxAccountStore) {
        self.store = store
        quotaRefresh = CloudQuotaRefresh { [weak self] in self?.refreshQuotas() }
        store.onChange = { [weak self] in self?.install() }
        install()
    }
    private func install() {
        MainActor.assumeIsolated {
            let live = Set(store.accounts.map(\.id))
            for id in providers.keys where !live.contains(id) {
                RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: id).url); providers[id] = nil; quotas[id] = nil
            }
            for account in store.accounts {
                guard let client = store.client(for: account.id) else { continue }
                if providers[account.id]?.client !== client {
                    let provider = DropboxProvider(client: client); providers[account.id] = provider
                    RemoteFS.registerCloud(provider, for: DropboxLocation(accountID: account.id).url)
                    DropboxEditing.shared.restore(client)
                    fetchQuota(account.id)
                    client.onFreshness = { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: self.key(account))
                        }
                    }
                }
            }
        }
        onChange?()
    }
    private func accountKey(_ id: UUID) -> String? { MainActor.assumeIsolated { store.accounts.first { $0.id == id }.map(key) } }
    private func key(_ account: DropboxAccount) -> String {
        "dropbox:" + account.id.uuidString.lowercased() + ":" + account.rootNamespaceID
    }
    private func account(_ key: String) -> DropboxAccount? { MainActor.assumeIsolated { store.accounts.first { self.key($0) == key } } }
    private func provider(_ url: URL) -> DropboxProvider? {
        guard let location = DropboxLocation(url: url) else { return nil }; return providers[location.accountID]
    }
    public var accounts: [CloudAccount] {
        MainActor.assumeIsolated {
            store.accounts.map { account in
                CloudAccount(
                    id: key(account), provider: .dropbox, email: account.email, displayName: account.displayName,
                    quotaUsed: quotas[account.id]?.used, quotaTotal: quotas[account.id]?.total,
                    sharedDriveCount: account.hasTeamSpace ? 1 : 0, status: store.status[account.id] ?? .ok)
            }
        }
    }
    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void,
        done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        authenticate(nil, openBrowser: openBrowser) { result in done(result) }
    }
    private func authenticate(
        _ expected: DropboxAccount?, openBrowser: @escaping (URL) -> Void,
        done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let account = try await store.connect(expected: expected, openBrowser: { openBrowser($0) }); install()
                setActive(true); done(.success(accounts.first { $0.id == self.key(account) }!))
            } catch {
                done(.failure(.from(error) { id in self.accountKey(id).flatMap { key in self.accounts.first { $0.id == key } } }))
            }
        }
        return { task.cancel() }
    }
    public func signInAgain(
        _ id: String, openBrowser: @escaping (URL) -> Void,
        done: @escaping (Result<Void, CloudConnectError>) -> Void
    ) -> () -> Void {
        guard let account = account(id) else { done(.failure(.failed("This account is no longer connected."))); return {} }
        return authenticate(account, openBrowser: openBrowser) { done($0.map { _ in () }) }
    }
    public func remove(_ id: String, done: @escaping (Error?) -> Void) {
        guard let account = account(id) else { done(nil); return }
        Task { @MainActor in
            do {
                // Nothing may still write into the account's folder while it is removed.
                await providers[account.id]?.stopFeeds()
                try await store.disconnect(account.id); install(); done(nil)
            } catch { done(error) }
        }
    }
    public func url(_ id: String, root: CloudRoot) -> URL {
        guard let account = account(id) else { return URL(string: "cloud-disconnected:///")! }
        return DropboxLocation(
            accountID: account.id,
            itemID: root == .sharedWithMe ? "collection:shared" : "",
            namespaceID: root == .sharedDrives ? account.rootNamespaceID : account.homeNamespaceID
        ).url
    }
    public func accountID(for url: URL) -> String? {
        guard let location = DropboxLocation(url: url) else { return nil }
        return MainActor.assumeIsolated { store.accounts.first { $0.id == location.accountID }.map(key) }
    }
    public func info(for url: URL) -> CloudItemInfo? {
        guard let file = provider(url)?.metadata(url) else { return nil }
        return CloudItemInfo(name: file.name, isFolder: file.isFolder)
    }
    public func permissions(for url: URL) -> CloudPermissions? {
        guard let location = DropboxLocation(url: url), provider(url) != nil else { return nil }
        if location.itemID.hasPrefix("collection:") { return CloudPermissions(collection: .sharedWithMe) }
        let file = provider(url)?.metadata(url)
        return CloudPermissions(
            canAddChildren: location.itemID.isEmpty || file?.isFolder == true, canRename: file != nil,
            canTrash: file != nil, canMove: file != nil, canCopy: true, name: file?.name)
    }
    public func content(for accountID: String) -> CloudContentSource? { account(accountID).flatMap { providers[$0.id]?.client.contentSource } }
    public func content(for url: URL) -> CloudContentSource? { try? provider(url)?.scoped(url).contentSource }
    public func savedAt(for folder: URL) -> Date? {
        guard let location = DropboxLocation(url: folder), let client = try? provider(folder)?.scoped(folder) else { return nil }
        return client.metadataCache.snapshot(location.itemID)?.savedAt
    }
    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(folder, done: done) { provider in
            let client = try provider.scoped(folder); let parent = try await provider.path(folder)
            return provider.item(try await client.createFolder(name: name, parent: parent), client: client)
        }
    }
    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(url, done: done) { provider in
            let client = try provider.scoped(url); let file = try await client.metadata(provider.location(url).itemID)
            return provider.item(try await client.rename(file, to: name), client: client)
        }
    }
    private func run<T>(_ url: URL, done: @escaping (Result<T, Error>) -> Void, work: @escaping (DropboxProvider) async throws -> T) {
        guard let provider = provider(url) else { done(.failure(DropboxError.reconnect)); return }
        Task { @MainActor in
            do { let result = try await work(provider); done(.success(result)); changed(url) } catch { done(.failure(Self.editError(error))) }
        }
    }
    public func trash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) {
        Task { @MainActor in
            var removed: [URL] = []; var failure: Error?
            for url in urls {
                do {
                    guard let provider = provider(url) else { throw DropboxError.reconnect }
                    let client = try provider.scoped(url); let file = try await client.metadata(provider.location(url).itemID)
                    _ = try await client.delete(file, confirmedWithoutUndo: true); removed.append(url); changed(url)
                } catch { failure = Self.editError(error) }
            }
            done(removed, failure)
        }
    }
    public func untrash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) { done([], DropboxError.unsupportedUndo) }
    public func avatar(_ id: String, done: @escaping (Data?) -> Void) { done(nil) }
    /// Tries each account until one can see the linked item.
    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {
        guard CloudProviderDescriptor.linkProvider(text)?.provider == .dropbox, let link = URL(string: text.trimmingCharacters(in: .whitespaces))
        else { done(.notALink); return }
        let clients = MainActor.assumeIsolated { store.accounts.compactMap { store.client(for: $0.id) } }
        Task { @MainActor [weak self] in
            for client in clients {
                guard let item = try? await client.sharedLink(link), let provider = self?.providers[client.accountID] else { continue }
                let url = provider.item(item, client: client).url
                done(item.isFolder ? .folder(url) : .file(url))
                return
            }
            done(.noAccess)
        }
    }
    /// Dropbox locations name only the item: its folders are found by path among the items already read, and the
    /// ones not read yet are fetched (they show the next time the location is drawn).
    public func ancestors(of url: URL) -> [URL] {
        guard let provider = provider(url), let location = try? provider.location(url), let client = try? provider.scoped(url),
            !location.itemID.isEmpty, !location.itemID.hasPrefix("collection:")
        else { return [] }
        let root = DropboxLocation(accountID: location.accountID, namespaceID: location.namespaceID).url
        guard let path = client.metadataCache.file(location.itemID)?.pathLower else {
            // Not read yet (a location opened directly): the item is read, then its folders.
            fetchAncestors([location.itemID], client: client, account: location.accountID)
            return [root]
        }
        let names = path.split(separator: "/").dropLast()
        let paths = names.indices.map { i in "/" + names[...i].joined(separator: "/") }
        let wanted = Set(paths)
        var folders: [String: DropboxItem] = [:]
        for file in client.metadataCache.files where file.isFolder { if let p = file.pathLower, wanted.contains(p) { folders[p] = file } }
        let missing = paths.filter { folders[$0] == nil }
        if !missing.isEmpty { fetchAncestors(missing, client: client, account: location.accountID) }
        return [root] + paths.compactMap { folders[$0].map { provider.item($0, client: client).url } }
    }
    private func fetchAncestors(_ paths: [String], client: DropboxClient, account: UUID) {
        let key = client.accountID.uuidString + (client.namespaceID ?? "")
        let wanted = paths.filter { !ancestorFetches.contains(key + $0) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { ancestorFetches.insert(key + $0) }
        Task { @MainActor [weak self] in
            for path in wanted { _ = try? await client.metadata(path) }
            guard let self, let dropbox = store.accounts.first(where: { $0.id == account }) else { return }
            NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: self.key(dropbox))
        }
    }
    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?,
        done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        let task = Task { @MainActor in
            do {
                guard let provider = provider(folder) else { throw DropboxError.reconnect }
                let client = try provider.scoped(folder)
                let path = everywhere ? "" : try await provider.path(folder)
                let page = try await client.search(text, path: path, contents: contents, cursor: pageToken)
                let items = page.items.filter { everywhere || $0.parentPath == path.lowercased() }.map { provider.item($0, client: client) }
                try Task.checkCancellation(); done(.success(CloudSearchPage(items: items, nextPageToken: page.cursor)))
            } catch { if !Task.isCancelled { done(.failure(error)) } }
        }
        return { task.cancel() }
    }
    @MainActor private func refreshQuotas() { for account in store.accounts { fetchQuota(account.id) } }
    @MainActor private func fetchQuota(_ id: UUID) {
        guard let client = store.client(for: id), fetchingQuota.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.fetchingQuota.remove(id) }
            guard let value = try? await client.spaceUsage(), self?.store.client(for: id) === client else { return }
            self?.quotas[id] = value; self?.onChange?()
        }
    }
    public func checkForChanges(_ id: String?) {
        MainActor.assumeIsolated {
            for account in store.accounts where id == nil || key(account) == id { fetchQuota(account.id) }
        }
        for (uuid, provider) in providers where id == nil || account(id!)?.id == uuid {
            Task { try? await provider.checkForChanges() }
        }
    }
    public func setActive(_ active: Bool) {
        MainActor.assumeIsolated { quotaRefresh?.setActive(active) }
        providers.values.forEach { $0.setActive(active) }
    }
    private func changed(_ url: URL) { NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: accountID(for: url)) }
    /// Dropbox's error as the message bar says it after "Couldn’t rename “Q3”.", as Drive's are.
    static func editError(_ error: Error) -> Error {
        switch error as? DropboxError {
        case .reconnect: return CloudEditError.denied("Sign in to Dropbox again to make changes.")
        case .offline: return CloudEditError.denied("You’re offline. Nothing was changed.")
        case .notFound: return CloudEditError.denied("It’s no longer in Dropbox, or no longer shared with you.")
        case .conflict: return CloudEditError.denied("An item with that name is already there, or it changed meanwhile.")
        case .api(429, _), .http(429): return CloudEditError.denied("Dropbox is busy. Try again in a moment.")
        default: return error
        }
    }
}
