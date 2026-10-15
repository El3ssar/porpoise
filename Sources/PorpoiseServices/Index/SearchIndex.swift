import Foundation
import PorpoiseCore

/// Explicit opt-in: no volume or folder is crawled until it appears in this configuration.
public struct IndexConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var roots: [String] = []
    public var exclusions = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs").path,
    ]
    public var excludeGitObjects = true
    public var excludeNodeModules = true
    public var content = false
    public init() {}
}

/// All mutation is serialized; immutable snapshots can be scanned on any query thread. Cancellation is synchronous.
public final class SearchIndex: @unchecked Sendable {
    public static let shared = SearchIndex()
    public static let changed = Notification.Name("PorpoiseIndexChanged")
    public struct Status: Sendable {
        public var count = 0
        public var updated: Date?
        public var building = false
        public var message = "Index off"
        public var warning: String?
    }
    private struct Chunk {
        var path: String
        var table: NameIndex
        var shadowed = 0
        var file = UUID().uuidString + ".idx"
    }
    private struct Root {
        var path: String
        var base: NameIndex
        var patches: [Chunk] = []
        var holes: [String] = []
        var file = UUID().uuidString + ".idx"
    }
    private struct Manifest: Codable {
        var configuration: IndexConfiguration
        var eventID: UInt64
        var updated: Date
        var roots: [RootFile]
    }
    private struct RootFile: Codable {
        var path: String
        var base: String
        var patches: [PatchFile]
        var holes: [String]
    }
    private struct PatchFile: Codable { var path: String; var file: String; var shadowed: Int }
    private let queue = DispatchQueue(label: "app.porpoise.index", qos: .utility)
    private let lock = NSLock()
    private var current = IndexConfiguration()
    private var state = Status()
    private var roots: [Root] = []
    private var revision = 0
    private var eventID: UInt64 = 0
    private var events: IndexEvents?
    private let directory: URL
    private let storagePath: String
    private let defaults: UserDefaults
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/SearchIndex", isDirectory: true)
        storagePath = IndexPath.canonical(self.directory.path)
        if let data = defaults.data(forKey: "searchIndex.configuration"), let c = try? JSONDecoder().decode(IndexConfiguration.self, from: data) {
            current = c
        }
    }
    public var configuration: IndexConfiguration { lock.withLock { current } }
    public var status: Status { lock.withLock { state } }
    public var statusText: String {
        let s = status
        if s.building { return "Index building…" }
        guard let updated = s.updated else { return s.message }
        return "Index: \(s.count.formatted()) items, updated \(max(0, Int(Date().timeIntervalSince(updated))))s ago"
            + (s.warning.map { " · " + $0 } ?? "")
    }
    /// Cheap UI hint: no filesystem calls. The worker search performs canonical/device coverage checks.
    public func hasReadySnapshot(for scope: URL) -> Bool {
        lock.withLock {
            let path = scope.path
            return current.enabled && !state.building && !excluded(path, config: current)
                && roots.contains { NameIndex.contains(path: path, in: $0.path) }
                && !roots.flatMap(\.holes).contains { NameIndex.contains(path: $0, in: path) || NameIndex.contains(path: path, in: $0) }
        }
    }
    public func start() { configure(configuration, rebuild: false) }
    public func configure(_ proposed: IndexConfiguration, rebuild: Bool = false) {
        var config = proposed
        config.roots = Array(Set(config.roots.map { IndexPath.canonical($0) })).sorted()
        // Nested roots would duplicate hits and could cross otherwise disabled volumes.
        config.roots = config.roots.filter { p in !config.roots.contains { $0 != p && NameIndex.contains(path: p, in: $0) && Self.sameVolume(p, $0) }
        }
        config.exclusions = config.exclusions.map { IndexPath.canonical($0) }
        let generation = lock.withLock { () -> Int in
            current = config; revision += 1; roots = []; state = Status(); state.building = config.enabled && !config.roots.isEmpty
            state.message = config.enabled ? "Select folders to index" : "Index off"
            return revision
        }
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "searchIndex.configuration") }
        let selected = config
        queue.async { [self] in
            events = nil
            guard selected.enabled, !selected.roots.isEmpty, valid(generation) else { notify(); return }
            if !rebuild,
                let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))),
                manifest.configuration == selected
            {
                do {
                    let loaded = try manifest.roots.map { root in
                        Root(
                            path: root.path, base: try read(root.base),
                            patches: try root.patches.map { Chunk(path: $0.path, table: try read($0.file), shadowed: $0.shadowed, file: $0.file) },
                            holes: root.holes, file: root.base)
                    }
                    guard publish(loaded, updated: manifest.updated, generation: generation) else { return }
                    eventID = manifest.eventID
                    guard watch(selected, generation: generation) else { return }
                    notify(); return
                } catch { /* Corrupt/obsolete snapshots are rebuilt; the search fallback stays available. */  }
            }
            eventID = IndexEvents.currentEventID
            guard watch(selected, generation: generation) else { return }  // Start before crawling so changes during the walk are replayed.
            var built: [Root] = []
            let crawlLock = NSLock(), workers = OperationQueue()
            workers.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.processorCount)
            for path in selected.roots {
                workers.addOperation { [self] in
                    let result = crawl(path, config: selected, generation: generation)
                    if result.table.count > 0 { crawlLock.withLock { built.append(Root(path: path, base: result.table, holes: result.holes)) } }
                }
            }
            workers.waitUntilAllOperationsAreFinished()
            built.sort { $0.path < $1.path }
            guard publish(built, updated: Date(), generation: generation) else { return }
            persist(selected, snapshot: built); notify()
        }
        notify()
    }
    private func publish(_ snapshot: [Root], updated: Date, generation: Int) -> Bool {
        lock.withLock {
            guard revision == generation else { return false }
            roots = snapshot; state.building = false; state.updated = updated
            state.count = snapshot.reduce(0) { $0 + $1.base.count + $1.patches.reduce(0) { $0 + $1.table.count - $1.shadowed } }
            state.warning = snapshot.contains { !$0.holes.isEmpty } ? "Some folders unreadable; regular search used for those scopes" : nil
            return true
        }
    }
    private func valid(_ generation: Int) -> Bool { lock.withLock { revision == generation } }
    private func read(_ file: String) throws -> NameIndex {
        guard !file.contains("/"), file.hasSuffix(".idx") else { throw NameIndex.Corrupt.snapshot }
        return try NameIndex(encoded: Data(contentsOf: directory.appendingPathComponent(file), options: .mappedIfSafe))
    }
    private static func sameVolume(_ a: String, _ b: String) -> Bool {
        var left = stat(), right = stat()
        return stat(a, &left) == 0 && stat(b, &right) == 0 && left.st_dev == right.st_dev
    }
    private func excluded(_ path: String, config: IndexConfiguration) -> Bool {
        NameIndex.contains(path: path, in: storagePath) || config.exclusions.contains { NameIndex.contains(path: path, in: $0) }
            || (config.excludeGitObjects && (path.hasSuffix("/.git/objects") || path.contains("/.git/objects/")))
            || (config.excludeNodeModules && path.split(separator: "/").contains("node_modules"))
    }
    private func crawl(_ path: String, config: IndexConfiguration, generation: Int) -> (table: NameIndex, holes: [String]) {
        guard !excluded(path, config: config) else { return (NameIndex(), []) }
        var holes: [String] = []
        let table = IndexCrawler.crawl(
            path, exclusions: config.exclusions, content: config.content, cancelled: { !self.valid(generation) },
            unreadable: { holes.append($0) }, skip: { self.excluded($0, config: config) })
        return (table, holes)
    }
    private func watch(_ config: IndexConfiguration, generation: Int) -> Bool {
        events = IndexEvents(roots: config.roots, since: eventID) { [weak self] paths, id, rescan in
            self?.queue.async { [weak self] in self?.refresh(paths, event: id, rescan: rescan, config: config, generation: generation) }
        }
        guard events?.available == true else {
            lock.withLock {
                roots = []; state = Status(); state.message = "Index watcher unavailable; using regular search"
            }
            notify(); return false
        }
        return true
    }
    private func refresh(_ paths: [String], event: UInt64, rescan: Bool, config: IndexConfiguration, generation: Int) {
        guard valid(generation) else { return }
        // Our manifest and snapshot writes must never feed back into the index.
        let paths = paths.map(IndexPath.entry).filter { rescan || !excluded($0, config: config) }
        guard !paths.isEmpty else { eventID = max(eventID, event); return }
        var copy = lock.withLock { roots }
        for r in copy.indices {
            var touched = Set(paths.filter { NameIndex.contains(path: $0, in: copy[r].path) || NameIndex.contains(path: copy[r].path, in: $0) })
            if touched.isEmpty { continue }
            if touched.count > 64 {
                touched = Set(
                    touched.map { p in
                        p == copy[r].path ? p : (p as NSString).deletingLastPathComponent
                    })
            }
            if rescan || touched.contains(copy[r].path) {
                let result = crawl(copy[r].path, config: config, generation: generation)
                copy[r] = Root(path: copy[r].path, base: result.table, holes: result.holes)
                continue
            }
            // Patches never overlap. A change inside an existing patch re-walks that patch.
            touched = Set(touched.map { p in copy[r].patches.first(where: { NameIndex.contains(path: p, in: $0.path) })?.path ?? p })
            let top = touched.filter { p in !touched.contains { $0 != p && NameIndex.contains(path: p, in: $0) } }
            for path in top where !excluded(path, config: config) {
                let result = crawl(path, config: config, generation: generation)
                copy[r].holes.removeAll { NameIndex.contains(path: $0, in: path) }
                copy[r].holes.append(contentsOf: result.holes)
                copy[r].patches.removeAll { NameIndex.contains(path: $0.path, in: path) }
                // Empty table is a deletion tombstone.
                copy[r].patches.append(Chunk(path: path, table: result.table, shadowed: copy[r].base.countUnderPath(path)))
            }
            if copy[r].patches.count >= 1024 {
                let result = crawl(copy[r].path, config: config, generation: generation)
                copy[r] = Root(path: copy[r].path, base: result.table, holes: result.holes)
            }
        }
        guard publish(copy, updated: Date(), generation: generation) else { return }
        eventID = max(eventID, event)
        persist(config, snapshot: copy); notify()
    }
    private func persist(_ config: IndexConfiguration, snapshot: [Root]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var files: [RootFile] = []
            for root in snapshot {
                let base = root.file
                if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(base).path) {
                    try root.base.encoded().write(to: directory.appendingPathComponent(base), options: .atomic)
                }
                var patches: [PatchFile] = []
                for patch in root.patches {
                    let file = patch.file
                    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
                        try patch.table.encoded().write(to: directory.appendingPathComponent(file), options: .atomic)
                    }
                    patches.append(PatchFile(path: patch.path, file: file, shadowed: patch.shadowed))
                }
                files.append(RootFile(path: root.path, base: base, patches: patches, holes: root.holes))
            }
            let manifest = Manifest(configuration: config, eventID: eventID, updated: Date(), roots: files)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            let keep = Set(files.flatMap { [$0.base] + $0.patches.map(\.file) })
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "idx" && !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        } catch { lock.withLock { state.warning = "Index could not be saved: \(error.localizedDescription)" } }
    }
    private func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) } }

    /// nil means uncovered/not ready: caller must retain fd/ripgrep/Spotlight fallback.
    public func search(
        _ text: String, scope: URL, contents: Bool = false, limit: Int = 5000,
        cancelled: () -> Bool = { false }
    ) -> (paths: [String], snippets: [String: String], error: String?)? {
        let (config, snapshot, building) = lock.withLock { (current, roots, state.building) }
        let scope = IndexPath.canonical(scope.path)
        let hasHoles = snapshot.flatMap(\.holes).contains { NameIndex.contains(path: $0, in: scope) || NameIndex.contains(path: scope, in: $0) }
        guard config.enabled, !building, !hasHoles, !excluded(scope, config: config),
            snapshot.contains(where: { NameIndex.contains(path: scope, in: $0.path) && Self.sameVolume(scope, $0.path) }), !contents || config.content
        else { return nil }
        let query: IndexQuery
        do { query = try contents ? IndexQuery(literal: text) : IndexQuery(text) } catch { return ([], [:], error.localizedDescription) }
        var found: [String] = [], snippets: [String: String] = [:]
        for root in snapshot where NameIndex.contains(path: scope, in: root.path) || NameIndex.contains(path: root.path, in: scope) {
            let excludedPaths = root.patches.map(\.path)
            let chunks = [Chunk(path: root.path, table: root.base)] + root.patches
            for (number, chunk) in chunks.enumerated() {
                let exclusions = number == 0 ? excludedPaths : []
                let ids = chunk.table.search(query, scope: scope, limit: limit, excluding: exclusions, cancelled: cancelled)
                found.append(contentsOf: ids.map { chunk.table.path($0) })
                if contents {
                    // Bloom candidates are always verified against current bytes. Unindexed files are included.
                    for id in chunk.table.contentCandidates(text, scope: scope, cancelled: cancelled) {
                        if cancelled() { return ([], [:], nil) }
                        let p = chunk.table.path(id)
                        guard !exclusions.contains(where: { NameIndex.contains(path: p, in: $0) }), !found.contains(p),
                            let value = IndexFileText.read(p, limit: 5_000_000),
                            let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: {
                                IndexQuery.fold(String($0)).contains(IndexQuery.fold(text))
                            })
                        else { continue }
                        found.append(p); snippets[p] = FolderSearch.snippet(String(line), around: text)
                        if found.count >= limit { break }
                    }
                }
                if found.count >= limit || cancelled() { break }
            }
        }
        return (Array(found.prefix(limit)), snippets, nil)
    }
}
