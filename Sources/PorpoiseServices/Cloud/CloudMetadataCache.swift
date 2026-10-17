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
    /// Bumped by each `remember` (what a change made here returned). A listing or a page of changes fetched before
    /// then is older than what it remembered: it passes the generation it started at, and doesn't put that back.
    private var current: UInt64 = 0
    private var rememberedAt: [String: UInt64] = [:]
    /// Where the cache is now: what a listing or a page of changes starts from (`store(_:key:since:)`, `apply`).
    public var generation: UInt64 { lock.withLock { current } }
    private var path: URL { directory.appendingPathComponent("metadata.json") }
    public init(directory: URL) {
        self.directory = directory
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
    public func remember(_ files: [Item]) {
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
            state.cursors[scope] = token; persist()
        }
    }
    public func invalidate(_ key: String? = nil) {
        lock.withLock {
            if let key { state.listings[key] = nil } else { state.listings.removeAll() }; persist()
        }
    }
    public func apply(
        _ files: [Item], removed: [String], belongs: (String, Item) -> Bool, retainExisting: (String) -> Bool = { _ in false },
        since: UInt64? = nil
    ) {
        lock.withLock {
            let files = files.map { newest($0, since: since) }
            let removed = Set(removed)
            for id in removed { state.files[id] = nil }
            for file in files where !removed.contains(file.id) { state.files[file.id] = file }
            for key in state.listings.keys {
                guard var snapshot = state.listings[key] else { continue }
                snapshot.files.removeAll { removed.contains($0.id) }
                for file in files where !removed.contains(file.id) {
                    let member = belongs(key, file)
                    if let index = snapshot.files.firstIndex(where: { $0.id == file.id }) {
                        if retainExisting(key) || member { snapshot.files[index] = file } else { snapshot.files.remove(at: index) }
                    } else if member {
                        snapshot.files.append(file)
                    }
                }
                state.listings[key] = snapshot
            }
            persist()
        }
    }
    public func clear() {
        lock.withLock {
            state = State(); try? FileManager.default.removeItem(at: path)
        }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { /* Disposable metadata: memory remains usable if persistence is unavailable. */  }
    }
}
