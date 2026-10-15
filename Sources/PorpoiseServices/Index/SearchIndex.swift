import Foundation
import PorpoiseCore

/// Explicit opt-in: no volume or folder is crawled until it appears in this configuration.
public struct IndexConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var roots: [String] = []
    public var exclusions = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path,
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs").path]
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
    private let defaults: UserDefaults
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/SearchIndex", isDirectory: true)
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
    }
    public func start() { configure(configuration, rebuild: false) }
    public func configure(_ proposed: IndexConfiguration, rebuild: Bool = false) {
        var config = proposed
        config.roots = Array(Set(config.roots.map { IndexPath.canonical($0) })).sorted()
        // Nested roots would duplicate hits and could cross otherwise disabled volumes.
        config.roots = config.roots.filter { p in !config.roots.contains { $0 != p && NameIndex.contains(path: p, in: $0) && Self.sameVolume(p, $0) } }
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
            if !rebuild, let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))), manifest.configuration == selected {
                do {
                    let loaded = try manifest.roots.map { root in
                        Root(path: root.path, base: try read(root.base), patches: try root.patches.map { Chunk(path: $0.path, table: try read($0.file), shadowed: $0.shadowed, file: $0.file) }, file: root.base)
                    }
                    guard valid(generation) else { return }
                    lock.withLock { roots = loaded; state.building = false; state.updated = manifest.updated; state.count = loaded.reduce(0) { $0 + $1.base.count + $1.patches.reduce(0) { $0 + $1.table.count - $1.shadowed } } }
                    eventID = manifest.eventID
                    watch(selected, generation: generation)
                    notify(); return
                } catch { /* Corrupt/obsolete snapshots are rebuilt; the search fallback stays available. */ }
            }
            eventID = 0
            watch(selected, generation: generation) // Start before crawling so changes during the walk are replayed.
            var built: [Root] = []
            let crawlLock = NSLock(), workers = OperationQueue()
            workers.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.processorCount)
            for path in selected.roots {
                workers.addOperation { [self] in
                    let table = crawl(path, config: selected, generation: generation)
                    if table.count > 0 { crawlLock.withLock { built.append(Root(path: path, base: table)) } }
                }
            }
            workers.waitUntilAllOperationsAreFinished()
            built.sort { $0.path < $1.path }
            guard valid(generation) else { return }
            lock.withLock { roots = built; state.building = false; state.updated = Date(); state.count = built.reduce(0) { $0 + $1.base.count } }
            persist(selected); notify()
        }
        notify()
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
        config.exclusions.contains { NameIndex.contains(path: path, in: $0) }
        || (config.excludeGitObjects && (path.hasSuffix("/.git/objects") || path.contains("/.git/objects/")))
        || (config.excludeNodeModules && path.split(separator: "/").contains("node_modules"))
    }
    private func crawl(_ path: String, config: IndexConfiguration, generation: Int) -> NameIndex {
        guard !excluded(path, config: config) else { return NameIndex() }
        return IndexCrawler.crawl(path, exclusions: config.exclusions, content: config.content, cancelled: { !self.valid(generation) },
                                  skip: { self.excluded($0, config: config) })
    }
    private func watch(_ config: IndexConfiguration, generation: Int) {
        events = IndexEvents(roots: config.roots, since: eventID) { [weak self] paths, id, rescan in
            self?.queue.async { [weak self] in self?.refresh(paths, event: id, rescan: rescan, config: config, generation: generation) }
        }
    }
    private func refresh(_ paths: [String], event: UInt64, rescan: Bool, config: IndexConfiguration, generation: Int) {
        guard valid(generation) else { return }
        var copy = lock.withLock { roots }
        for r in copy.indices {
            var touched = Set(paths.map { IndexPath.canonical($0) }.filter { NameIndex.contains(path: $0, in: copy[r].path) || NameIndex.contains(path: copy[r].path, in: $0) })
            if touched.isEmpty { continue }
            if rescan || touched.contains(copy[r].path) {
                copy[r] = Root(path: copy[r].path, base: crawl(copy[r].path, config: config, generation: generation))
                continue
            }
            // Patches never overlap. A change inside an existing patch re-walks that patch.
            touched = Set(touched.map { p in copy[r].patches.first(where: { NameIndex.contains(path: p, in: $0.path) })?.path ?? p })
            let top = touched.filter { p in !touched.contains { $0 != p && NameIndex.contains(path: p, in: $0) } }
            for path in top where !excluded(path, config: config) {
                let table = crawl(path, config: config, generation: generation)
                copy[r].patches.removeAll { NameIndex.contains(path: $0.path, in: path) }
                copy[r].patches.append(Chunk(path: path, table: table, shadowed: copy[r].base.countUnderPath(path))) // Empty table is a deletion tombstone.
            }
        }
        guard valid(generation) else { return }
        eventID = max(eventID, event)
        lock.withLock { roots = copy; state.updated = Date(); state.count = copy.reduce(0) { $0 + $1.base.count + $1.patches.reduce(0) { $0 + $1.table.count - $1.shadowed } } }
        persist(config); notify()
    }
    private func persist(_ config: IndexConfiguration) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let snapshot = lock.withLock { roots }
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
                files.append(RootFile(path: root.path, base: base, patches: patches))
            }
            let manifest = Manifest(configuration: config, eventID: eventID, updated: Date(), roots: files)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            let keep = Set(files.flatMap { [$0.base] + $0.patches.map(\.file) })
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "idx" && !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        } catch { lock.withLock { state.message = "Index could not be saved: \(error.localizedDescription)" } }
    }
    private func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) } }

    /// nil means uncovered/not ready: caller must retain fd/ripgrep/Spotlight fallback.
    public func search(_ text: String, scope: URL, contents: Bool = false, limit: Int = 5000,
                       cancelled: () -> Bool = { false }) -> (paths: [String], snippets: [String: String])? {
        let (config, snapshot, building) = lock.withLock { (current, roots, state.building) }
        let scope = IndexPath.canonical(scope.path)
        guard config.enabled, !building, !excluded(scope, config: config), snapshot.contains(where: { NameIndex.contains(path: scope, in: $0.path) && Self.sameVolume(scope, $0.path) }), !contents || config.content else { return nil }
        guard let query = try? (contents ? IndexQuery(literal: text) : IndexQuery(text)) else { return ([], [:]) }
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
                        if cancelled() { return ([], [:]) }
                        let p = chunk.table.path(id)
                        guard !exclusions.contains(where: { NameIndex.contains(path: p, in: $0) }), !found.contains(p),
                            let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                            (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 5_000_000,
                            let data = try? Data(contentsOf: URL(fileURLWithPath: p)), !data.contains(0),
                            let value = String(data: data, encoding: .utf8),
                            let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: { IndexQuery.fold(String($0)).contains(IndexQuery.fold(text)) }) else { continue }
                        found.append(p); snippets[p] = FolderSearch.snippet(String(line), around: text)
                        if found.count >= limit { break }
                    }
                }
                if found.count >= limit || cancelled() { break }
            }
        }
        return (Array(found.prefix(limit)), snippets)
    }
}
