import Foundation

public struct CloudKeepPlan: Equatable, Sendable {
    public var bytes: Int64
    public var items: Int
    public var available: Int64
    public var fits: Bool
    public var needsConfirmation: Bool { bytes >= 1_000_000_000 || items >= 500 }
    public init(bytes: Int64, items: Int, available: Int64, fits: Bool? = nil) {
        self.bytes = bytes; self.items = items; self.available = available; self.fits = fits ?? (bytes <= available)
    }
}

public struct CloudOfflineUsage: Equatable, Sendable {
    public var account: String
    public var kept: Int64
    public var recent: Int64
    public init(account: String = "", kept: Int64 = 0, recent: Int64 = 0) {
        self.account = account; self.kept = kept; self.recent = recent
    }
}

/// Synchronous snapshot for menus and Properties. All access to the facade is on the main queue.
public struct CloudOfflineDetails: Equatable, Sendable {
    public var downloaded = false
    public var kept = false
    public var inheritedFrom: String?
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var items = 0
    public var totalItems = 0
    public var progress: Double?
    public var error: String?
    public var export: String?
    public init() {}
}

/// Provider-neutral, main-queue surface. Notifications carry affected URLs in userInfo["urls"].
/// The facade owns account stores; UI consumers never need a Drive client or filesystem path.
public final class CloudOffline: @unchecked Sendable {
    public static let shared = CloudOffline()
    public static let changed = Notification.Name("PorpoiseCloudOfflineChanged")
    static let spaceChanged = Notification.Name("PorpoiseCloudOfflineSpaceChanged")
    public let accounts: CloudAccounts
    public var operations = FileOperationsController.shared
    public var removalDenial: (URL) -> String? = { _ in nil }
    private var accountsWatch: NSObjectProtocol?
    private var accountStatus: [String: CloudAccount.Status] = [:]
    private var backgroundTasks: [String: Task<Void, Error>] = [:]
    private var backgroundPending: [String: [String: CloudRemoteItem]] = [:]
    private let resolveSource: ((URL) -> CloudContentSource?)?
    public var root: URL
    /// Only recent copies count towards this limit. nil means no limit.
    public var recentLimit: Int64? = 5_000_000_000 {
        didSet {
            Settings.store.set(recentLimit ?? -1, forKey: "cloudOfflineRecentLimit")
            for store in stores.values { Task { try? await store.setRecentLimit(recentLimit) } }
        }
    }
    private var stores: [String: CloudOfflineStore] = [:]
    private var keepers: [String: CloudPinKeeper] = [:]
    private var snapshots: [String: CloudOfflineSnapshot] = [:]
    private var sources: [String: CloudContentSource] = [:]
    private var epochs: [String: UUID] = [:]
    public var editHeld: @Sendable (CloudItemRef) async -> Bool = { _ in false }

    public init(accounts: CloudAccounts = .shared, root: URL? = nil, source: ((URL) -> CloudContentSource?)? = nil) {
        self.resolveSource = source
        self.accounts = accounts
        if let stored = Settings.store.object(forKey: "cloudOfflineRecentLimit") as? NSNumber {
            self.recentLimit = stored.int64Value < 0 ? nil : stored.int64Value
        }
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/Cloud", isDirectory: true)
    }

    public func source(for url: URL) -> CloudContentSource? {
        if let resolveSource { return resolveSource(url) }
        guard let id = accounts.backend?.accountID(for: url) else { return nil }
        return accounts.backend?.content(for: id)
    }

    public func activate() {
        if accountsWatch == nil {
            accountsWatch = NotificationCenter.default.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAccounts()
            }
        }
        refreshAccounts()
    }
    private func refreshAccounts() {
        for account in accounts.accounts {
            guard let source = accounts.backend?.content(for: account.id) else { continue }
            let existed = stores[account.id] != nil
            let cameOnline = accountStatus[account.id] != .ok && account.status == .ok
            accountStatus[account.id] = account.status
            _ = try? store(for: source)
            if existed && cameOnline { Task { await keepers[account.id]?.resume() } }
        }
    }
    deinit { if let accountsWatch { NotificationCenter.default.removeObserver(accountsWatch) } }

    @MainActor private func backgroundUpdate(_ items: [CloudRemoteItem], source: CloudContentSource, store: CloudOfflineStore) async throws {
        let id = source.accountID
        for item in items { backgroundPending[id, default: [:]][item.ref.item] = item }
        if let running = backgroundTasks[id] { try await running.value; return }
        let task = Task { @MainActor in
            let urls = items.map { source.url(for: $0) }
            _ = try await operations.cloudTask(title: "Updating offline copies · \(items.count) files", sources: urls, quiet: true) { context in
                let worker = CloudPinKeeper(store: store)
                var completed: [URL] = []
                while let pending = self.backgroundPending.removeValue(forKey: id), !pending.isEmpty {
                    let batch = Array(pending.values)
                    do { try await worker.download(batch, context: context) } catch {
                        for item in batch where self.backgroundPending[id]?[item.ref.item] == nil {
                            self.backgroundPending[id, default: [:]][item.ref.item] = item
                        }
                        throw error
                    }
                    completed += batch.map { source.url(for: $0) }
                }
                return completed
            }
        }
        backgroundTasks[id] = task
        defer { backgroundTasks[id] = nil }
        try await task.value
    }

    public var cacheLimit: Int64? {
        get { recentLimit }
        set { recentLimit = newValue }
    }
    public func supports(_ url: URL) -> Bool { source(for: url)?.ref(for: url) != nil }
    public func keepDenial(for url: URL) -> String? {
        guard let source = source(for: url), let ref = source.ref(for: url) else { return CloudContentError.unsupported.localizedDescription }
        if source.cachedItem(ref)?.canDownload == false { return "The owner turned off copying and downloading." }
        return nil
    }
    public func keep(_ urls: [URL]) { _ = keep(true, urls) }
    public func stopKeeping(_ urls: [URL]) { _ = keep(false, urls) }
    public func downloadNow(_ urls: [URL]) { _ = downloadNow(urls, done: { _ in }) }
    public func removeRecent(account: String) { removeRecent(account: account, done: { _ in }) }

    public func details(for url: URL) -> CloudOfflineDetails {
        guard let source = source(for: url), let ref = source.ref(for: url) else { return CloudOfflineDetails() }
        _ = try? store(for: source)
        guard let snapshot = snapshots[ref.account] else { return CloudOfflineDetails() }
        var result = CloudOfflineDetails()
        let item = snapshot.items[ref.item] ?? source.cachedItem(ref)
        result.kept = snapshot.isKept(ref.item)
        result.inheritedFrom = snapshot.inheritedPin(ref.item).flatMap { snapshot.items[$0]?.name }
        result.downloaded = snapshot.entries[ref.item] != nil
        result.progress = snapshot.progress[ref.item]
        result.error = snapshot.errors[ref.item]
        result.export = item?.export
        let ids: Set<String>
        if item?.isFolder == true {
            ids = Set(
                snapshot.items.keys.filter { id in
                    var queue = snapshot.items[id]?.parents ?? []; var seen: Set<String> = []
                    while let parent = queue.popLast() {
                        if parent == ref.item { return true }
                        if seen.insert(parent).inserted { queue += snapshot.items[parent]?.parents ?? [] }
                    }
                    return false
                })
        } else {
            ids = [ref.item]
        }
        for id in ids {
            if let entry = snapshot.entries[id] { result.bytes += entry.size; result.items += 1 }
            if let child = snapshot.items[id], !child.isFolder { result.totalBytes += child.size ?? 0; result.totalItems += 1 }
        }
        if item?.isFolder == true { result.downloaded = result.items > 0 }
        return result
    }
    public func state(for url: URL) -> CloudState {
        guard let source = source(for: url), let ref = source.ref(for: url),
            source.cachedItem(ref)?.isFolder != true
        else { return .local }
        let details = details(for: url)
        if details.progress != nil { return .downloading }
        return details.downloaded ? .local : .cloudOnly
    }
    public func usage(account: String) -> CloudOfflineUsage {
        var usage = snapshots[account]?.usage ?? CloudOfflineUsage()
        usage.account = account
        return usage
    }

    /// Lazily opens the account index, then reconciles its persisted pins in the background.
    public func store(for source: CloudContentSource) throws -> CloudOfflineStore {
        if let existing = stores[source.accountID], sources[source.accountID] === source { return existing }
        if let old = keepers[source.accountID] { Task { await old.stop() } }
        let id = source.accountID, epoch = UUID()
        epochs[id] = epoch; sources[id] = source
        let store = try CloudOfflineStore(
            source: source,
            directory: source.offlineDirectory
                ?? root.appendingPathComponent(cloudObjectKey(source.providerTitle)).appendingPathComponent(cloudObjectKey(id)),
            recentLimit: recentLimit,
            held: { [editHeld] ref in
                if await source.holdsCopy(ref) { return true }
                return await editHeld(ref)
            }
        ) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.epochs[id] == epoch else { return }
                self.snapshots[id] = snapshot
                let urls = snapshot.items.values.map { source.url(for: $0) }
                NotificationCenter.default.post(name: Self.changed, object: urls, userInfo: ["urls": urls])
            }
        }
        stores[id] = store
        let keeper = CloudPinKeeper(store: store) { [weak self] items in
            guard let self else { return }
            try await self.backgroundUpdate(items, source: source, store: store)
        }; keepers[id] = keeper
        Task {
            await store.publish(); await keeper.start()
        }
        return store
    }

    @discardableResult
    public func plan(keep urls: [URL], done: @escaping (Result<CloudKeepPlan, Error>) -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do {
                var bytes: Int64 = 0, count = 0, available = Int64.max
                for (source, refs) in try grouped(urls) {
                    let store = try store(for: source)
                    let items = try await keepers[source.accountID]!.descendants(refs)
                    for item in items where !item.isFolder { bytes += item.size ?? 0; count += 1 }
                    let space = await store.space(); available = min(available, max(0, space.available - space.reserve))
                }
                try Task.checkCancellation()
                done(.success(CloudKeepPlan(bytes: bytes, items: count, available: available)))
            } catch { done(.failure(error)) }
        }
        return { task.cancel() }
    }
    @discardableResult
    public func downloadNow(_ urls: [URL], done: @escaping (Error?) -> Void) -> () -> Void {
        run(urls, pin: nil, done: done)
    }
    @discardableResult
    public func keep(_ on: Bool, _ urls: [URL], done: @escaping (Error?) -> Void = { _ in }) -> () -> Void {
        run(urls, pin: on, done: done)
    }
    private func grouped(_ urls: [URL]) throws -> [(CloudContentSource, [CloudItemRef])] {
        var groups: [String: (CloudContentSource, [CloudItemRef])] = [:]
        for url in urls {
            guard let source = source(for: url), let ref = source.ref(for: url) else { throw CloudContentError.unsupported }
            if groups[ref.account] == nil { groups[ref.account] = (source, []) }
            if groups[ref.account]?.1.contains(ref) != true { groups[ref.account]?.1.append(ref) }
        }
        return Array(groups.values)
    }
    private func run(_ urls: [URL], pin: Bool?, done: @escaping (Error?) -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do {
                for (source, refs) in try grouped(urls) {
                    let store = try store(for: source)
                    if pin == false { try await store.unpin(refs); continue }
                    // Persist intent before network access, including while offline.
                    let cached = refs.compactMap { source.cachedItem($0) }
                    try await store.remember(cached)
                    if pin == true { try await store.pin(refs) }
                    let name = cached.first?.name ?? "files"
                    let title = pin == true ? "Keeping “\(name)” downloaded" : "Downloading offline copies"
                    let keeper = keepers[source.accountID]!
                    _ = try await operations.cloudTask(title: title, sources: urls) { context in
                        try await context.checkpoint()
                        let items = try await keeper.descendants(refs)
                        try await keeper.download(items, context: context)
                        return items.filter { !$0.isFolder }.map { source.url(for: $0) }
                    }
                }
                done(nil)
            } catch { done(error) }
        }
        return { task.cancel() }
    }
    /// Refusals known to the snapshot are returned immediately; byte removal runs off the main thread.
    public func removeDownload(_ urls: [URL]) -> [String] {
        var refused: [String] = []
        for url in urls {
            guard let source = source(for: url), let ref = source.ref(for: url), let store = try? store(for: source) else { continue }
            if let reason = removalDenial(url) { refused.append(reason); continue }
            if let parent = details(for: url).inheritedFrom {
                refused.append("Kept because “\(parent)” is kept downloaded."); continue
            }
            if let snapshot = snapshots[ref.account] {
                for item in snapshot.items.values where isDescendant(item.ref.item, of: ref.item, snapshot: snapshot) {
                    if let reason = removalDenial(source.url(for: item)) { refused.append(reason) }
                }
            }
            Task { @MainActor in
                do {
                    let snapshot = await store.snapshot()
                    let refs = snapshot.items.values.filter { item in
                        item.ref == ref || self.isDescendant(item.ref.item, of: ref.item, snapshot: snapshot)
                    }.map(\.ref)
                    if await source.holdsCopy(ref) { throw CloudContentError.heldForEditing }
                    try await store.unpin([ref])
                    for child in refs.isEmpty ? [ref] : refs {
                        do { try await store.remove([child], unpin: false) } catch CloudContentError.heldForEditing { continue }
                    }
                    NotificationCenter.default.post(name: Self.spaceChanged, object: nil)
                    await keepers[ref.account]?.resume()
                } catch { NotificationCenter.default.post(name: Self.changed, object: [url], userInfo: ["error": error.localizedDescription]) }
            }
        }
        return refused
    }
    private func isDescendant(_ id: String, of parent: String, snapshot: CloudOfflineSnapshot) -> Bool {
        var pending = snapshot.items[id]?.parents ?? [], seen: Set<String> = []
        while let next = pending.popLast() {
            if next == parent { return true }
            if seen.insert(next).inserted { pending += snapshot.items[next]?.parents ?? [] }
        }
        return false
    }
    public func removeRecent(account: String, done: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                try await stores[account]?.removeRecent(); NotificationCenter.default.post(name: Self.spaceChanged, object: nil);
                await keepers[account]?.resume(); done(nil)
            } catch { done(error) }
        }
    }
    public func wipe(account: String, done: @escaping (Error?) -> Void = { _ in }) {
        epochs[account] = nil
        backgroundTasks.removeValue(forKey: account)?.cancel(); backgroundPending[account] = nil
        let store = stores.removeValue(forKey: account), keeper = keepers.removeValue(forKey: account)
        snapshots[account] = nil; sources[account] = nil; accountStatus[account] = nil
        Task { @MainActor in
            await keeper?.stop()
            do { try await store?.wipe(); done(nil) } catch { done(error) }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}
