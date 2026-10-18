import Foundation
import PorpoiseCore

/// Box policy behind the same account/edit/search/offline contracts the UI uses for every provider.
public final class BoxCloudBackend: CloudBackend {
    public var onChange: (() -> Void)?
    public let store: BoxAccountStore
    private var quotas: [UUID: BoxClient.Quota] = [:]
    private var fetchingQuota: Set<UUID> = []
    private var quotaRefresh: CloudQuotaRefresh?
    private var providers: [UUID: BoxProvider] = [:]
    /// Folders above a location being read once (by account and item), so drawing doesn't ask again.
    private var ancestorFetches: Set<String> = []
    @MainActor public init(store: BoxAccountStore) {
        self.store = store
        quotaRefresh = CloudQuotaRefresh { [weak self] in self?.refreshQuotas() }
        store.onChange = { [weak self] in self?.install() }
        install()
    }
    private func install() {
        MainActor.assumeIsolated {
            let live = Set(store.accounts.map(\.id))
            for id in providers.keys where !live.contains(id) {
                RemoteFS.registerCloud(nil, for: BoxLocation(accountID: id).url); providers[id] = nil; quotas[id] = nil
            }
            for account in store.accounts {
                guard let client = store.client(for: account.id) else { continue }
                if providers[account.id]?.client !== client {
                    let provider = BoxProvider(client: client); providers[account.id] = provider
                    RemoteFS.registerCloud(provider, for: BoxLocation(accountID: account.id).url)
                    CloudEditing.shared.restore(client)
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
    private func key(_ account: BoxAccount) -> String { "box:" + account.id.uuidString.lowercased() }
    private func account(_ key: String) -> BoxAccount? { MainActor.assumeIsolated { store.accounts.first { self.key($0) == key } } }
    private func provider(_ url: URL) -> BoxProvider? {
        guard let location = BoxLocation(url: url) else { return nil }; return providers[location.accountID]
    }
    public var accounts: [CloudAccount] {
        MainActor.assumeIsolated {
            store.accounts.map { account in
                CloudAccount(
                    id: key(account), provider: .box, email: account.email, displayName: account.displayName, quotaUsed: quotas[account.id]?.used,
                    quotaTotal: quotas[account.id]?.total, sharedDriveCount: 0, status: store.status[account.id] ?? .ok)
            }
        }
    }
    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        authenticate(nil, openBrowser: openBrowser) { result in done(result) }
    }
    private func authenticate(
        _ expected: BoxAccount?, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
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
    public func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void) -> () ->
        Void
    {
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
        return BoxLocation(accountID: account.id).url
    }
    public func accountID(for url: URL) -> String? {
        guard let location = BoxLocation(url: url) else { return nil }
        return MainActor.assumeIsolated { store.accounts.first { $0.id == location.accountID }.map(key) }
    }
    public func info(for url: URL) -> CloudItemInfo? {
        guard let file = provider(url)?.metadata(url) else { return nil }
        return CloudItemInfo(name: file.name, isFolder: file.isFolder)
    }
    public func permissions(for url: URL) -> CloudPermissions? {
        guard let location = BoxLocation(url: url), let provider = provider(url) else { return nil }
        let file = provider.metadata(url), changeable = file != nil && file?.isRoot == false
        return CloudPermissions(
            canAddChildren: location.itemID.isEmpty || file?.isFolder == true, canRename: changeable, canTrash: changeable, canMove: changeable,
            canCopy: file?.kind != .webLink, name: file?.name)
    }
    public func content(for accountID: String) -> CloudContentSource? { account(accountID).flatMap { providers[$0.id]?.client.contentSource } }
    public func content(for url: URL) -> CloudContentSource? { provider(url)?.client.contentSource }
    public func savedAt(for folder: URL) -> Date? {
        guard let location = BoxLocation(url: folder), let client = provider(folder)?.client else { return nil }
        return client.metadataCache.snapshot(location.apiID)?.savedAt
    }
    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(folder, done: done) { provider in provider.item(try await provider.client.createFolder(name: name, parentID: provider.folderID(folder))) }
    }
    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(url, done: done) { provider in provider.item(try await provider.client.rename(provider.fetch(url), to: name)) }
    }
    private func run<T>(_ url: URL, done: @escaping (Result<T, Error>) -> Void, work: @escaping (BoxProvider) async throws -> T) {
        guard let provider = provider(url) else { done(.failure(BoxError.reconnect)); return }
        Task { @MainActor in
            do { let result = try await work(provider); done(.success(result)); changed(url) } catch { done(.failure(Self.editError(error))) }
        }
    }
    /// Deletes go to Box's trash; Undo restores them where they were (`untrash`).
    public func trash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) {
        Task { @MainActor in
            var removed: [URL] = []; var failure: Error?
            for url in urls {
                do {
                    guard let provider = provider(url) else { throw BoxError.reconnect }
                    _ = try await provider.client.delete(provider.fetch(url)); removed.append(url); changed(url)
                } catch { failure = Self.editError(error) }
            }
            done(removed, failure)
        }
    }
    /// Restores from Box's trash. A name taken meanwhile is refused by Box: nothing there is replaced.
    public func untrash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) {
        Task { @MainActor in
            var restored: [URL] = []; var failure: Error?
            for url in urls {
                do {
                    guard let provider = provider(url) else { throw BoxError.reconnect }
                    let location = try provider.location(url)
                    let item = try await provider.client.restore(location.apiID, kind: location.kind)
                    restored.append(provider.item(item).url); changed(url)
                } catch { failure = Self.editError(error) }
            }
            done(restored, failure)
        }
    }
    public func avatar(_ id: String, done: @escaping (Data?) -> Void) { done(nil) }
    /// Tries each account until one can open the linked item as itself.
    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {
        guard CloudProviderDescriptor.linkProvider(text)?.provider == .box, let link = URL(string: text.trimmingCharacters(in: .whitespaces)) else {
            done(.notALink); return
        }
        let clients = MainActor.assumeIsolated { store.accounts.compactMap { store.client(for: $0.id) } }
        Task { @MainActor [weak self] in
            for client in clients {
                guard let item = try? await client.sharedLink(link), let provider = self?.providers[client.accountID] else { continue }
                let url = provider.item(item).url
                done(item.isFolder ? .folder(url) : .file(url))
                return
            }
            done(.noAccess)
        }
    }
    /// Box locations name only the item: its folders are found by parent ID among the items already read, and the ones
    /// not read yet are fetched (they show the next time the location is drawn).
    public func ancestors(of url: URL) -> [URL] {
        guard let provider = provider(url), let location = try? provider.location(url), !location.itemID.isEmpty else { return [] }
        let client = provider.client, root = BoxLocation(accountID: location.accountID).url
        guard var file = client.metadataCache.file(location.itemID) else {
            fetchAncestors([location.itemID], client: client, account: location.accountID)
            return [root]
        }
        var chain: [URL] = [], seen: Set<String> = [file.id]
        while let parent = file.parentID, parent != BoxItem.rootID, seen.insert(parent).inserted {
            guard let folder = client.metadataCache.file(parent) else {
                fetchAncestors([parent], client: client, account: location.accountID); break
            }
            chain.insert(provider.item(folder).url, at: 0); file = folder
        }
        return [root] + chain
    }
    private func fetchAncestors(_ ids: [String], client: BoxClient, account: UUID) {
        let key = client.accountID.uuidString + "\n"
        let wanted = ids.filter { !ancestorFetches.contains(key + $0) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { ancestorFetches.insert(key + $0) }
        Task { @MainActor [weak self] in
            for id in wanted { _ = try? await client.metadata(id) }
            guard let self, let box = store.accounts.first(where: { $0.id == account }) else { return }
            wanted.forEach { self.ancestorFetches.remove(key + $0) }
            NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: self.key(box))
        }
    }
    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?, done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        let task = Task { @MainActor in
            do {
                guard let provider = provider(folder) else { throw BoxError.reconnect }
                let id = everywhere ? BoxItem.rootID : try provider.folderID(folder)
                let page = try await provider.client.search(text, in: id, contents: contents, cursor: pageToken)
                let items = page.items.filter { everywhere || $0.parentID == id }.map(provider.item)
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
            guard let value = try? await client.quota(), self?.store.client(for: id) === client else { return }
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
    /// Box's error as the message bar says it after "Couldn’t rename “Q3”.", as the other providers' are.
    static func editError(_ error: Error) -> Error {
        switch error as? BoxError {
        case .reconnect: return CloudEditError.denied("Sign in to Box again to make changes.")
        case .offline: return CloudEditError.denied("You’re offline. Nothing was changed.")
        case .notFound: return CloudEditError.denied("It’s no longer in Box, or no longer shared with you.")
        case .conflict: return CloudEditError.denied("An item with that name is already there, or it changed meanwhile.")
        case .unsupportedUndo: return CloudEditError.denied("Box can’t restore this item from here. It’s in Box’s trash.")
        case .api(429, _), .http(429), .api(503, _): return CloudEditError.denied("Box is busy. Try again in a moment.")
        case .api(403, _): return CloudEditError.denied("You don’t have permission to change this in Box.")
        default: return error
        }
    }
}
