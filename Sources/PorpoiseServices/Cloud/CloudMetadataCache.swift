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
    public func snapshot(_ key: String) -> Snapshot? { lock.withLock { state.listings[key] } }
    public func file(_ id: String) -> Item? { lock.withLock { state.files[id] } }
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
            for file in files { state.files[file.id] = file }
            persist()
            return files
        }
    }
    public func alias(_ id: String, to file: Item) {
        lock.withLock {
            state.files[id] = file; persist()
        }
    }
    /// `since`: the `generation` the listing was fetched from; what was remembered after it is kept.
    public func store(_ files: [Item], key: String, since: UInt64? = nil) {
        lock.withLock {
            let files = files.map { newest($0, since: since) }
            state.listings[key] = Snapshot(files: files, savedAt: Date())
            for file in files { state.files[file.id] = file }
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
                state.listings.removeAll(); persist()
            }
        }
    }
    /// Drops these listings at once (a scope reset names one per folder).
    public func invalidate<Keys: Sequence>(keys: Keys) where Keys.Element == String {
        lock.withLock {
            var changed = false
            for key in keys where state.listings.removeValue(forKey: key) != nil { changed = true }
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
            for id in removed { state.files[id] = nil }
            let changed = files.filter { !removed.contains($0.id) }
            guard !changed.isEmpty || !removed.isEmpty else { return [] }
            for file in changed { state.files[file.id] = file }
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
        if !madeDirectory {
            madeDirectory = true
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard !dirty else { return }
        dirty = true
        CloudStateWriter.shared.schedule(path.path) { [self] in write() }
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
