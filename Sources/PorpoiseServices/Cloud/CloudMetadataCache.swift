import Foundation

public protocol CloudMetadataItem: Codable, Sendable { var id: String { get } }

/// Disposable, versioned metadata snapshots and opaque cursors. Provider adapters define listing membership.
public final class CloudMetadataCache<Item: CloudMetadataItem>: @unchecked Sendable {
    public struct Snapshot: Codable, Sendable {
        public var files: [Item]
        public var savedAt: Date
    }
    private struct State: Codable {
        var schema = 1
        var files: [String: Item] = [:]
        var listings: [String: Snapshot] = [:]
        var cursors: [String: String] = [:]
    }
    public let directory: URL
    private let lock = NSLock()
    private var state: State
    /// Changed since the last write. The file is written a moment later, off the lock (`CloudStateWriter`): encoding
    /// tens of MB on every lookup held readers, navigation included, for seconds.
    private var dirty = false
    private var madeDirectory = false
    /// Bumped by every change: what a `derived` value was computed from.
    private var revision: UInt64 = 0
    private var derivedValues: [String: (revision: UInt64, value: Any)] = [:]
    /// Bumped by each `remember` (what a change made here returned). A listing or a page of changes fetched before
    /// then is older than what it remembered: it passes the generation it started at, and doesn't put that back.
    private var current: UInt64 = 0
    private var rememberedAt: [String: UInt64] = [:]
    struct RetentionConfiguration: Sendable {
        var limits = CloudMetadataRetention.Limits(files: 20_000, listings: 128, bytes: 64 * 1024 * 1024)
        var aliases: @Sendable (Item) -> Set<String> = { _ in [] }
        var parents: @Sendable (Item) -> Set<String> = { _ in [] }
        var context: @Sendable (String) -> Set<String> = { [$0] }
        var roots: Set<String> = []
    }
    struct RestoredOwner: Sendable {
        var owner: CloudMetadataRetention.Owner
        var files: [Item] = []
        var complete = true
    }
    private let retentionQueue = DispatchQueue(label: "app.porpoise.cloud-metadata-retention", qos: .utility)
    private var retentionConfiguration: RetentionConfiguration?
    private var retentionReady = false
    private var retentionJob: UUID?
    private var owners: [String: CloudMetadataRetention.Owner] = [:]
    private var ownerVersions: [String: UInt64] = [:]
    private var failedOwnerItems: [String: Set<String>] = [:]
    private var ownerRevision: UInt64 = 0
    private var reads: [UUID: UInt64] = [:]
    private var accessClock: UInt64 = 0
    private var fileAccess: [String: UInt64] = [:]
    private var listingAccess: [String: UInt64] = [:]
    private var lastRetentionAccounting: CloudMetadataRetention.Accounting?
    /// Where the cache is now: what a listing or a page of changes starts from (`store(_:key:since:)`, `apply`).
    public var generation: UInt64 { lock.withLock { current } }
    private var path: URL { directory.appendingPathComponent("metadata.json") }
    public init(directory: URL) {
        self.directory = directory
        // What another cache on this folder hasn't written yet is newer than the file.
        CloudStateWriter.shared.flush(directory.appendingPathComponent("metadata.json").path)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
            let decoded = try? JSONDecoder().decode(State.self, from: data), decoded.schema == 1
        {
            state = decoded
        } else {
            state = State()
        }
    }
    public func snapshot(_ key: String) -> Snapshot? {
        lock.withLock {
            if retentionConfiguration != nil, state.listings[key] != nil { accessClock &+= 1; listingAccess[key] = accessClock }
            return state.listings[key]
        }
    }
    public func file(_ id: String) -> Item? {
        lock.withLock {
            guard let file = state.files[id] else { return nil }
            if retentionConfiguration != nil { accessClock &+= 1; fileAccess[file.id] = accessClock }
            return file
        }
    }
    public var files: [Item] { lock.withLock { Array(state.files.values) } }
    /// A value computed from every cached file (an index by path, say), kept until the cache next changes, so that
    /// lookups between changes don't each scan the account.
    public func derived<Value>(_ name: String, _ build: ([String: Item]) -> Value) -> Value {
        lock.withLock {
            if let cached = derivedValues[name], cached.revision == revision, let value = cached.value as? Value { return value }
            let value = build(state.files)
            derivedValues[name] = (revision, value)
            return value
        }
    }
    public func remember(_ files: [Item]) {
        guard !files.isEmpty else { return }
        lock.withLock {
            current += 1
            for file in files {
                state.files[file.id] = file
                rememberedAt[file.id] = current
                touched(file.id)
            }
            persist()
        }
    }
    /// `file`, or what was remembered of it since `since` (newer than a listing fetched from then).
    private func newest(_ file: Item, since: UInt64?) -> Item {
        guard let since, let at = rememberedAt[file.id], at > since, let newer = state.files[file.id] else { return file }
        return newer
    }
    /// Metadata read from the provider (a listing, a lookup) as it was when `since` was the `generation`: kept, unless
    /// what a change made here remembered since is newer. Returns what the cache keeps for each.
    @discardableResult public func learn(_ files: [Item], since: UInt64) -> [Item] {
        guard !files.isEmpty else { return [] }
        return lock.withLock {
            let files = files.map { newest($0, since: since) }
            for file in files { state.files[file.id] = file; touched(file.id) }
            persist()
            return files
        }
    }
    public func alias(_ id: String, to file: Item) {
        lock.withLock {
            state.files[id] = file
            if state.files[file.id] == nil { state.files[file.id] = file }
            touched(file.id); persist()
        }
    }
    /// `since`: the `generation` the listing was fetched from; what was remembered after it is kept.
    public func store(_ files: [Item], key: String, since: UInt64? = nil) {
        lock.withLock {
            let files = files.map { newest($0, since: since) }
            state.listings[key] = Snapshot(files: files, savedAt: Date())
            for file in files { state.files[file.id] = file; touched(file.id) }
            if retentionConfiguration != nil { accessClock &+= 1; listingAccess[key] = accessClock }
            persist()
        }
    }
    public func cursor(_ scope: String) -> String? { lock.withLock { state.cursors[scope] } }
    public func setCursor(_ token: String?, scope: String) {
        lock.withLock {
            // Polls set the same cursor again whenever nothing changed.
            guard state.cursors[scope] != token else { return }
            state.cursors[scope] = token; persist()
        }
    }
    public func invalidate(_ key: String? = nil) {
        if let key {
            invalidate(keys: [key])
        } else {
            lock.withLock {
                guard !state.listings.isEmpty else { return }
                state.listings.removeAll(); listingAccess.removeAll(); persist()
            }
        }
    }
    /// Drops these listings at once (a scope reset names one per folder).
    public func invalidate<Keys: Sequence>(keys: Keys) where Keys.Element == String {
        lock.withLock {
            var changed = false
            for key in keys where state.listings.removeValue(forKey: key) != nil { listingAccess[key] = nil; changed = true }
            if changed { persist() }
        }
    }
    @discardableResult public func apply(
        _ files: [Item], removed: [String], belongs: (String, Item) -> Bool, retainExisting: (String) -> Bool = { _ in false },
        since: UInt64? = nil
    ) -> [String] {
        lock.withLock {
            let files = files.map { newest($0, since: since) }
            let removed = Set(removed.filter { since == nil || (rememberedAt[$0] ?? 0) <= since! })
            for id in removed { state.files[id] = nil; fileAccess[id] = nil; rememberedAt[id] = nil }
            let changed = files.filter { !removed.contains($0.id) }
            guard !changed.isEmpty || !removed.isEmpty else { return [] }
            for file in changed { state.files[file.id] = file; touched(file.id) }
            for key in state.listings.keys {
                guard var snapshot = state.listings[key] else { continue }
                snapshot.files.removeAll { removed.contains($0.id) }
                // A page of changes looks files up in each listing once, rather than with a scan per changed file.
                var position =
                    changed.count > 8
                    ? [String: Int](snapshot.files.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }) : nil
                var dropped: Set<Int> = []
                for file in changed {
                    let member = belongs(key, file)
                    let found =
                        position.map { $0[file.id] }
                        ?? snapshot.files.indices.first { !dropped.contains($0) && snapshot.files[$0].id == file.id }
                    if let index = found {
                        if retainExisting(key) || member { snapshot.files[index] = file } else { dropped.insert(index); position?[file.id] = nil }
                    } else if member {
                        position?[file.id] = snapshot.files.count
                        snapshot.files.append(file)
                    }
                }
                if !dropped.isEmpty { snapshot.files = snapshot.files.enumerated().filter { !dropped.contains($0.offset) }.map(\.element) }
                state.listings[key] = snapshot
            }
            persist()
            return Array(removed)
        }
    }
    public func clear() {
        lock.withLock {
            state = State(); dirty = false; revision &+= 1
            derivedValues.removeAll()
            rememberedAt.removeAll()
            fileAccess.removeAll(); listingAccess.removeAll(); lastRetentionAccounting = nil
            scheduleRetention()
        }
        CloudStateWriter.shared.discard(path.path) { [path] in try? FileManager.default.removeItem(at: path) }
    }
    /// Writes what is pending now (tests, and a cache about to be dropped).
    public func flush() { CloudStateWriter.shared.flush(path.path) }
    /// Under the lock: marks the state changed and schedules one write for everything that changes meanwhile.
    private func persist() {
        revision &+= 1
        // A stale index can own every item from the previous revision. Release it when the source changes,
        // including when nobody asks for this particular index again.
        derivedValues.removeAll()
        scheduleRetention()
        if !madeDirectory {
            madeDirectory = true
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard !dirty else { return }
        dirty = true
        CloudStateWriter.shared.schedule(path.path) { [self] in write() }
    }
    /// Production adapters call this once, after choosing account/namespace-scoped ownership directories.
    /// Restoration runs before the first prune, without making lazy edit stores hash or open their local files.
    func enableRetention(
        _ configuration: RetentionConfiguration,
        restore: @escaping @Sendable () -> [String: RestoredOwner] = { [:] }
    ) {
        let initial = lock.withLock { () -> ([String: UInt64], Set<String>) in
            precondition(retentionConfiguration == nil)
            retentionConfiguration = configuration
            return (ownerVersions, Set(state.files.values.map(\.id)))
        }
        retentionQueue.async { [self] in
            let restored = restore()
            lock.withLock {
                for (name, value) in restored where ownerVersions[name] == initial.0[name] {
                    installOwner(name, value, unknownItems: initial.1)
                }
                ownerVersions.removeAll()
                retentionReady = true
                scheduleRetention()
            }
        }
    }

    func setRetentionLimits(_ limits: CloudMetadataRetention.Limits) {
        lock.withLock {
            retentionConfiguration?.limits = limits; ownerRevision &+= 1; scheduleRetention()
        }
    }
    var retentionAccounting: CloudMetadataRetention.Accounting? { lock.withLock { lastRetentionAccounting } }
    var retentionRestoreFailures: Int { lock.withLock { failedOwnerItems.count } }
    var retentionStorageCounts: (files: Int, listings: Int, remembered: Int, reads: Int, ownerVersions: Int) {
        lock.withLock { (fileAccess.count, listingAccess.count, rememberedAt.count, reads.count, ownerVersions.count) }
    }

    /// Register before persisting a pin/session. A newer live owner always wins over an older startup scan.
    func setRetentionOwner(_ name: String, _ value: RestoredOwner?) {
        lock.withLock { installOwner(name, value) }
    }
    private func installOwner(_ name: String, _ value: RestoredOwner?, unknownItems: Set<String>? = nil) {
        ownerRevision &+= 1
        if !retentionReady { ownerVersions[name] = ownerRevision }
        if let value {
            owners[name] = value.owner
            if !value.complete {
                if failedOwnerItems[name] == nil { failedOwnerItems[name] = unknownItems ?? Set(state.files.values.map(\.id)) }
            } else {
                failedOwnerItems[name] = nil
            }
            var added = false
            for file in value.files where state.files[file.id] == nil { state.files[file.id] = file; touched(file.id); added = true }
            if added { persist() }
        } else {
            owners[name] = nil; failedOwnerItems[name] = nil
        }
        scheduleRetention()
    }

    func retainMetadata(_ owner: CloudMetadataRetention.Owner) -> CloudMetadataLease {
        let name = "lease:" + UUID().uuidString
        let generation = lock.withLock { () -> UInt64 in
            installOwner(name, RestoredOwner(owner: owner)); return current
        }
        return CloudMetadataLease(generation: generation) { [weak self] in self?.setRetentionOwner(name, nil) }
    }
    /// Keep the returned lease alive through both the network read and any deferred change-page application.
    func beginRead() -> CloudMetadataLease {
        let id = UUID()
        let generation = lock.withLock { () -> UInt64 in
            reads[id] = current; ownerRevision &+= 1; return current
        }
        return CloudMetadataLease(generation: generation) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.reads[id] = nil; self.ownerRevision &+= 1; self.scheduleRetention()
            }
        }
    }
    private func touched(_ id: String) {
        guard retentionConfiguration != nil else { return }
        accessClock &+= 1; fileAccess[id] = accessClock
    }
    /// Called only with the lock held. No encoding, graph traversal or waiting on the caller's thread.
    private func scheduleRetention() {
        guard retentionConfiguration != nil, retentionReady, retentionJob == nil else { return }
        let id = UUID(); retentionJob = id
        retentionQueue.asyncAfter(deadline: .now() + 0.25) { [self] in
            let run = lock.withLock { () -> Bool in
                guard retentionJob == id else { return false }
                retentionJob = nil; return true
            }
            if run { _ = pruneRetention() }
        }
    }

    private struct RetentionPlan {
        var revision: UInt64
        var owners: UInt64
        var files: [String: UInt64]
        var listings: [String: UInt64]
        var evictions: CloudMetadataRetention.Evictions
        var actualKeys: [String]
        var cursors: [String]
        var accounting: CloudMetadataRetention.Accounting
    }
    private struct RetentionInput {
        var state: State
        var configuration: RetentionConfiguration
        var owners: [String: CloudMetadataRetention.Owner]
        var failures: [String: Set<String>]
        var remembered: [String: UInt64]
        var since: UInt64?
        var revision: UInt64
        var ownerRevision: UInt64
        var files: [String: UInt64]
        var listings: [String: UInt64]
    }
    /// The input's Item/COW state references die with this function, before the apply lock is taken.
    private func makeRetentionPlan() -> RetentionPlan? {
        guard
            let input = lock.withLock({ () -> RetentionInput? in
                guard let configuration = retentionConfiguration, retentionReady else { return nil }
                return RetentionInput(
                    state: state, configuration: configuration, owners: owners, failures: failedOwnerItems,
                    remembered: rememberedAt, since: reads.values.min(), revision: revision, ownerRevision: ownerRevision,
                    files: fileAccess, listings: listingAccess)
            })
        else { return nil }
        var groups: [String: [String: Item]] = [:]
        for (key, item) in input.state.files { groups[item.id, default: [:]][key] = item }
        var planner = CloudMetadataRetention()
        let encoder = JSONEncoder()
        for id in groups.keys.sorted(by: { (input.files[$0] ?? 0, $0) < (input.files[$1] ?? 0, $1) }) {
            let entries = groups[id]!
            guard let item = entries[id] ?? entries.sorted(by: { $0.key < $1.key }).first?.value else { continue }
            let aliases = input.configuration.aliases(item).union(entries.keys.filter { $0 != id })
            let parents = input.configuration.parents(item)
            // A codec failure cannot make an arbitrary payload look free: retain it as an explicit exception.
            let bytes = (try? encoder.encode(entries).count)
            planner.putFile(
                id, aliases: aliases, parents: parents,
                bytes: (bytes ?? 0) + ((try? encoder.encode(Array(aliases)).count) ?? 0) + ((try? encoder.encode(Array(parents)).count) ?? 0))
            if bytes == nil { planner.setOwner("codec:" + id, .init(items: [id])) }
        }
        for key in input.state.listings.keys.sorted(by: { (input.listings[$0] ?? 0, $0) < (input.listings[$1] ?? 0, $1) }) {
            let snapshot = input.state.listings[key]!
            let bytes = try? encoder.encode(snapshot).count
            planner.putListing(
                key, items: Set(snapshot.files.map(\.id)), context: input.configuration.context(key),
                bytes: (bytes ?? 0) + ((try? encoder.encode(key).count) ?? 0))
            if bytes == nil { planner.setOwner("codec-listing:" + key, .init(listings: [key])) }
        }
        var roots = input.configuration.roots
        for (key, item) in input.state.files where key != item.id { roots.insert(item.id) }
        planner.setOwner("roots", .init(items: roots))
        for (name, owner) in input.owners { planner.setOwner("owner:" + name, owner) }
        for (name, ids) in input.failures { planner.setOwner("restore:" + name, .init(items: ids)) }
        if let since = input.since {
            planner.setOwner("reads", .init(items: Set(input.remembered.filter { $0.value > since }.keys)))
        }
        let evicted = planner.prune(to: input.configuration.limits)
        return RetentionPlan(
            revision: input.revision, owners: input.ownerRevision,
            files: Dictionary(uniqueKeysWithValues: evicted.files.map { ($0, input.files[$0] ?? 0) }),
            listings: Dictionary(uniqueKeysWithValues: evicted.listings.map { ($0, input.listings[$0] ?? 0) }),
            evictions: evicted, actualKeys: input.state.files.compactMap { evicted.files.contains($0.value.id) ? $0.key : nil },
            cursors: input.state.cursors.keys.filter { $0.hasPrefix("listing:") && input.state.listings[String($0.dropFirst(8))] == nil },
            accounting: planner.accounting)
    }
    @discardableResult private func pruneRetention() -> Bool {
        guard let plan = makeRetentionPlan() else { return true }
        return lock.withLock {
            guard revision == plan.revision, ownerRevision == plan.owners,
                plan.files.allSatisfy({ (fileAccess[$0.key] ?? 0) == $0.value }),
                plan.listings.allSatisfy({ (listingAccess[$0.key] ?? 0) == $0.value })
            else { scheduleRetention(); return false }
            for key in plan.evictions.listings {
                state.listings[key] = nil; listingAccess[key] = nil
                state.cursors["listing:" + key] = nil
            }
            for key in plan.actualKeys { state.files[key] = nil }
            for id in plan.evictions.files { fileAccess[id] = nil; rememberedAt[id] = nil }
            for key in plan.cursors { state.cursors[key] = nil }
            lastRetentionAccounting = plan.accounting
            if !plan.evictions.files.isEmpty || !plan.evictions.listings.isEmpty || !plan.cursors.isEmpty { persist() }
            return true
        }
    }
    /// Test/diagnostic barrier; production paths register owners synchronously and never wait for pruning.
    func settleRetention() async {
        var complete = false
        while !complete && !Task.isCancelled {
            complete = await withCheckedContinuation { continuation in
                retentionQueue.async { [self] in
                    lock.withLock { retentionJob = nil }
                    continuation.resume(returning: pruneRetention())
                }
            }
        }
    }

    private func write() {
        let state: State? = lock.withLock {
            guard dirty else { return nil }
            dirty = false; return self.state
        }
        // A folder removed meanwhile (the account, a test's scratch folder) is not put back.
        guard let state, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try JSONEncoder().encode(state).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { /* Disposable metadata: memory remains usable if persistence is unavailable. */  }
    }
}

/// Writes cloud caches' files on one background queue, at most one write per file per `delay`. Each pending write
/// reads what its cache holds when it runs, so a burst of changes costs one encoding. Opening a cache on the same
/// file, `flushAll` (on quit) and `discard` run or drop what is pending first.
public final class CloudStateWriter: @unchecked Sendable {
    public static let shared = CloudStateWriter()
    private let queue = DispatchQueue(label: "app.porpoise.cloud-state-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: () -> Void] = [:]
    let delay: TimeInterval
    init(delay: TimeInterval = 1) { self.delay = delay }

    func schedule(_ path: String, write: @escaping () -> Void) {
        let first = lock.withLock {
            defer { pending[path] = write }
            return pending[path] == nil
        }
        if first { queue.asyncAfter(deadline: .now() + delay) { self.run(path) } }
    }
    private func run(_ path: String) { lock.withLock { pending.removeValue(forKey: path) }?() }
    /// Runs the pending write for `path`, after any write in progress (which may be that file's).
    func flush(_ path: String) { queue.sync { run(path) } }
    /// Drops a pending write and runs `then` after any write in progress.
    func discard(_ path: String, then: @escaping () -> Void) {
        queue.sync {
            _ = lock.withLock { pending.removeValue(forKey: path) }
            then()
        }
    }
    /// Writes everything pending now: on quit.
    public func flushAll() {
        queue.sync { for path in lock.withLock({ Array(pending.keys) }) { run(path) } }
    }
}
