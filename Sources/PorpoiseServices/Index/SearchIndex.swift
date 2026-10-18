import Foundation
import PorpoiseCore
import PorpoiseFileSystem

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
    /// Build folders (`buildFolderNames`): a build rewrites thousands of files in them, many times a minute while
    /// someone works (most of what a folder of projects reports).
    public var excludeBuildOutput = true
    public static let buildFolderNames = [".build", "DerivedData"]
    /// Folders macOS and apps keep writing to (`systemFolders`). Indexed, they report changes all the time (most of
    /// what a home folder reports) and hold nothing people look for.
    public var excludeSystemFolders = true
    public var content = false
    public init() {}
    /// Saved before a setting existed, a configuration gets that setting's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IndexConfiguration()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? defaults.roots
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? defaults.exclusions
        excludeGitObjects = try c.decodeIfPresent(Bool.self, forKey: .excludeGitObjects) ?? defaults.excludeGitObjects
        excludeNodeModules = try c.decodeIfPresent(Bool.self, forKey: .excludeNodeModules) ?? defaults.excludeNodeModules
        excludeBuildOutput = try c.decodeIfPresent(Bool.self, forKey: .excludeBuildOutput) ?? defaults.excludeBuildOutput
        excludeSystemFolders = try c.decodeIfPresent(Bool.self, forKey: .excludeSystemFolders) ?? defaults.excludeSystemFolders
        content = try c.decodeIfPresent(Bool.self, forKey: .content) ?? defaults.content
    }

    static let home = FilePath.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
    static let library = home + "/Library"
    /// In the Library, what people keep there themselves: cloud drives (iCloud Drive, and Dropbox, Google Drive or
    /// OneDrive through File Provider). Everything else in it is the system's and apps' own.
    static let libraryKept: Set<String> = ["CloudStorage", "Mobile Documents"]
    /// Shown in Settings.
    public static let systemFolders = ["~/Library (except cloud drives)", "~/.Trash"]
    /// Whether `path` is in one of `systemFolders`. A root chosen inside one is indexed all the same.
    func inSystemFolder(_ path: String) -> Bool {
        guard excludeSystemFolders else { return false }
        if FilePath.contains(path: path, in: Self.home + "/.Trash") {
            return !roots.contains { FilePath.contains(path: $0, in: Self.home + "/.Trash") }
        }
        guard path.hasPrefix(Self.library + "/") else { return false }
        let name = path.dropFirst(Self.library.count + 1).prefix { $0 != "/" }
        let folder = Self.library + "/" + name
        return !Self.libraryKept.contains(String(name)) && !roots.contains { FilePath.contains(path: $0, in: folder) }
    }
}

/// All mutation is serialized; immutable snapshots can be scanned on any query thread. Cancellation is synchronous.
public final class SearchIndex: @unchecked Sendable {
    public static let shared: SearchIndex = {
        let env = ProcessInfo.processInfo.environment
        // UI tests opt in explicitly, keeping both snapshots and defaults away from the user's index.
        if let suite = TestEnvironment.defaultsSuite.value(in: env), let path = TestEnvironment.testIndexDirectory.value(in: env),
            let defaults = UserDefaults(suiteName: suite)
        {
            return SearchIndex(directory: URL(fileURLWithPath: path), defaults: defaults)
        }
        return SearchIndex()
    }()
    public static let changed = Notification.Name("PorpoiseIndexChanged")
    public struct Status: Sendable {
        public var count = 0
        public var updated: Date?
        public var building = false
        public var message = "Index off"
        public var warning: String?
        public var pendingChanges = 0
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
        /// Raised when what an index holds for the same configuration changes: an older snapshot is built again.
        /// 2: build output and system folders excluded (none before 0.8.6).
        static let current = 2
        var version: Int? = Manifest.current
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
    /// Reported changes not applied yet. Always changed where it is stored (`pendingBuild?.add(…)`): a copy taken
    /// first (`if var pending = pendingBuild`) shares the set with the stored one, so adding to it copied the whole set
    /// on every batch, and a long stream of changes cost more for each new one (v0.8.5).
    struct Changes {
        var generation: Int
        var paths = Set<String>()
        var event: UInt64 = 0
        var rescan = false
        /// Past this many paths they are replaced by their folders (see `fold`), keeping a long stream's memory bounded.
        private(set) var foldAt = Changes.foldLimit
        static let foldLimit = 4096
        init(generation: Int) { self.generation = generation }
        mutating func add(_ new: [String], event: UInt64, rescan: Bool, roots: [String]) {
            self.event = max(self.event, event)
            self.rescan = self.rescan || rescan
            paths.formUnion(new)
            if paths.count > foldAt { fold(roots: roots) }
        }
        /// Each path becomes the folder holding it, walked again whole when the changes are applied, as an update
        /// does with many changes anyway. Only a folder inside a root: never the root, for what changed directly in it.
        /// The next fold waits until the set has doubled, so folding costs a constant amount per change even when it
        /// cannot shrink the set.
        mutating func fold(roots: [String]) {
            paths = Set(
                paths.map { p in
                    guard let slash = p.lastIndex(of: "/") else { return p }
                    let folder = String(p[..<slash])
                    return roots.contains { folder != $0 && FilePath.contains(path: folder, in: $0) } ? folder : p
                })
            foldAt = max(Changes.foldLimit, paths.count * 2)
        }
    }
    // A process-wide limit, rather than one pool per SearchIndex. Control queues never wait for these jobs.
    // One crawl at a time, on a serial queue of its own: such a queue always gets a thread. On the shared pool, utility
    // work got none while other work kept every core busy, and crawls stayed queued (CI's 3-core runner). Each crawl
    // reads folders on several threads itself, the calling one included.
    // Each work item drains its own autorelease pool: a serial queue kept busy by a changing tree never returns its
    // thread to the pool, and the URLs, paths and file caches Foundation autoreleases piled up (2.5 GB in 8 minutes).
    // Held: see below.
    private static let crawlThread = DispatchQueue(label: "app.porpoise.index-crawls", qos: .utility, autoreleaseFrequency: .workItem)
    private static let crawlers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.porpoise.index-crawls"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = crawlThread  // unowned(unsafe): the static above keeps it alive
        return queue
    }()
    private let queue = DispatchQueue(label: "app.porpoise.index", qos: .utility, autoreleaseFrequency: .workItem)
    /// Snapshot files known to be in `directory`: saving writes only new ones and removes only those it replaced,
    /// instead of checking and listing every file of the index on every update.
    private var savedFiles: Set<String>?
    private let crawlQueue: OperationQueue
    private var pendingBuild: Changes?
    /// Changes reported while an update was waiting or running, applied together by the next one: a busy tree
    /// reports changes many times a second, and each update walks the changed folders again and saves the index.
    private var queuedChanges: Changes?
    /// How long reported changes wait to be applied together.
    var updateDelay: TimeInterval = 0.25
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
    public convenience init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.init(directory: directory, defaults: defaults, crawlQueue: Self.crawlers)
    }
    init(directory: URL?, defaults: UserDefaults, crawlQueue: OperationQueue) {
        self.crawlQueue = crawlQueue
        self.defaults = defaults
        self.directory = directory ?? Settings.supportFolder.appendingPathComponent("SearchIndex", isDirectory: true)
        storagePath = FilePath.canonical(self.directory.path)
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
        return "Index: \(FileFormat.count(s.count)) items, updated \(max(0, Int(Date().timeIntervalSince(updated))))s ago"
            + (s.warning.map { " · " + $0 } ?? "")
    }
    /// Cheap UI hint: no filesystem calls. The worker search performs canonical/device coverage checks.
    public func hasReadySnapshot(for scope: URL) -> Bool {
        lock.withLock {
            let path = scope.path
            return current.enabled && !state.building && !excluded(path, config: current)
                && roots.contains { FilePath.contains(path: path, in: $0.path) }
                && !roots.flatMap(\.holes).contains { FilePath.contains(path: $0, in: path) || FilePath.contains(path: path, in: $0) }
        }
    }
    public func start() { configure(configuration, rebuild: false) }
    public func configure(_ proposed: IndexConfiguration, rebuild: Bool = false) {
        var config = proposed
        config.roots = Array(Set(config.roots.map { FilePath.canonical($0) })).sorted()
        // Nested roots would duplicate hits and could cross otherwise disabled volumes.
        config.roots = config.roots.filter { p in !config.roots.contains { $0 != p && FilePath.contains(path: p, in: $0) && Self.sameVolume(p, $0) }
        }
        config.exclusions = config.exclusions.map { FilePath.canonical($0) }
        let generation = lock.withLock { () -> Int in
            current = config; revision += 1; roots = []; state = Status(); state.building = config.enabled && !config.roots.isEmpty
            state.message = state.building ? "Index queued" : (config.enabled ? "Select folders to index" : "Index off")
            return revision
        }
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "searchIndex.configuration") }
        let selected = config
        queue.async { [self] in
            guard valid(generation) else { return }
            events = nil
            pendingBuild = nil
            queuedChanges = nil
            savedFiles = nil
            guard selected.enabled, !selected.roots.isEmpty, valid(generation) else { notify(); return }
            startupMessage("Index loading snapshot", generation: generation)
            if !rebuild,
                let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))),
                manifest.version == Manifest.current, manifest.configuration == selected
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
            startupMessage("Index starting watcher", generation: generation)
            guard watch(selected, generation: generation) else { return }  // Start before crawling so changes during the walk are replayed.
            startupMessage("Index queued for crawl", generation: generation)
            pendingBuild = Changes(generation: generation)
            var built: [Root] = []
            let crawlLock = NSLock(), group = DispatchGroup()
            for path in selected.roots {
                group.enter()
                crawlQueue.addOperation { [self] in
                    defer { group.leave() }
                    guard valid(generation) else { return }
                    startupMessage("Index crawling", generation: generation)
                    let result = crawl(path, config: selected, generation: generation)
                    if result.table.count > 0 { crawlLock.withLock { built.append(Root(path: path, base: result.table, holes: result.holes)) } }
                }
            }
            group.notify(queue: queue) { [self] in
                guard valid(generation), let pending = pendingBuild, pending.generation == generation else { return }
                pendingBuild = nil
                let snapshot = crawlLock.withLock { built.sorted { $0.path < $1.path } }
                // Keep fallback active until changes received during the crawl have also been applied.
                guard publish(snapshot, updated: Date(), generation: generation, building: !pending.paths.isEmpty) else { return }
                if pending.paths.isEmpty {
                    eventID = max(eventID, pending.event)
                    persist(selected, snapshot: snapshot); notify()
                } else {
                    refresh(Array(pending.paths), event: pending.event, rescan: pending.rescan, config: selected, generation: generation)
                }
            }
        }
        notify()
    }
    private func startupMessage(_ message: String, generation: Int) {
        lock.withLock {
            if revision == generation { state.message = message }
        }
    }
    private func publish(_ snapshot: [Root], updated: Date, generation: Int, building: Bool = false) -> Bool {
        lock.withLock {
            guard revision == generation else { return false }
            roots = snapshot; state.building = building; state.updated = updated
            if !building { state.pendingChanges = 0 }
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
        FilePath.contains(path: path, in: storagePath) || config.exclusions.contains { FilePath.contains(path: path, in: $0) }
            || config.inSystemFolder(path)
            || (config.excludeGitObjects && (path.hasSuffix("/.git/objects") || path.contains("/.git/objects/")))
            || (config.excludeNodeModules && path.split(separator: "/").contains("node_modules"))
            || (config.excludeBuildOutput
                && IndexConfiguration.buildFolderNames.contains { path.hasSuffix("/" + $0) || path.contains("/" + $0 + "/") })
    }
    private func crawl(_ path: String, config: IndexConfiguration, generation: Int) -> (table: NameIndex, holes: [String]) {
        guard !excluded(path, config: config) else { return (NameIndex(), []) }
        var holes: [String] = []
        // One update can walk many folders: what Foundation autoreleases on the way goes after each.
        let table = autoreleasepool {
            IndexCrawler.crawl(
                path, exclusions: config.exclusions, content: config.content, cancelled: { !self.valid(generation) },
                unreadable: { holes.append($0) }, skip: { self.excluded($0, config: config) })
        }
        return (table, holes)
    }
    private func watch(_ config: IndexConfiguration, generation: Int) -> Bool {
        // The index's own saves first: an index of the home folder would otherwise hear every one of them.
        var quiet = [storagePath] + config.exclusions
        if config.excludeSystemFolders { quiet.append(IndexConfiguration.home + "/.Trash") }
        events = IndexEvents(roots: config.roots, since: eventID, excluding: quiet) { [weak self] paths, id, rescan in
            self?.queue.async { [weak self] in self?.enqueue(paths, event: id, rescan: rescan, config: config, generation: generation) }
        }
        guard events?.available == true else {
            lock.withLock {
                guard revision == generation else { return }
                roots = []; state = Status(); state.message = "Index watcher unavailable; using regular search"
            }
            notify(); return false
        }
        return true
    }
    /// Collects reported changes; the first schedules the update that applies them all.
    private func enqueue(_ paths: [String], event: UInt64, rescan: Bool, config: IndexConfiguration, generation: Int) {
        guard valid(generation) else { return }
        // During the first crawl, changes are only noted (cheap), and the index isn't ready until they're applied.
        if pendingBuild?.generation == generation {
            return refresh(paths, event: event, rescan: rescan, config: config, generation: generation)
        }
        // Excluded changes go now: a busy excluded folder must not keep a growing set of changes waiting.
        let paths = rescan ? paths : paths.filter { !excluded($0, config: config) }
        if queuedChanges?.generation == generation {
            queuedChanges?.add(paths, event: event, rescan: rescan, roots: config.roots)
            return
        }
        guard !paths.isEmpty || rescan else { eventID = max(eventID, event); return }
        queuedChanges = Changes(generation: generation)
        queuedChanges?.add(paths, event: event, rescan: rescan, roots: config.roots)
        queue.asyncAfter(deadline: .now() + updateDelay) { [weak self] in
            guard let self, let queued = self.queuedChanges, queued.generation == generation else { return }
            self.queuedChanges = nil
            self.refresh(Array(queued.paths), event: queued.event, rescan: queued.rescan, config: config, generation: generation)
        }
    }
    /// Takes changes in as the watcher reports them, returning once they have been (tests).
    func receive(_ paths: [String], event: UInt64) {
        let (config, generation) = lock.withLock { (current, revision) }
        // Synchronous work runs on the calling thread, outside the queue's own autorelease pools.
        autoreleasepool { queue.sync { enqueue(paths, event: event, rescan: false, config: config, generation: generation) } }
    }
    /// How many changed paths wait for the next update (tests).
    var queuedPaths: Int { queue.sync { queuedChanges?.paths.count ?? 0 } }
    private func refresh(_ paths: [String], event: UInt64, rescan: Bool, config: IndexConfiguration, generation: Int) {
        guard valid(generation) else { return }
        // Our manifest and snapshot writes must never feed back into the index.
        let paths = paths.map(FilePath.entry).filter { rescan || !excluded($0, config: config) }
        if pendingBuild?.generation == generation {
            pendingBuild?.add(paths, event: event, rescan: rescan, roots: config.roots)
            if pendingBuild?.rescan == true || pendingBuild?.paths.count ?? 0 > 1024 {
                pendingBuild?.rescan = true
                pendingBuild?.paths = Set(config.roots)
            }
            let count = pendingBuild?.paths.count ?? 0
            lock.withLock { if revision == generation { state.pendingChanges = count } }
            return
        }
        guard !paths.isEmpty else { eventID = max(eventID, event); return }
        var copy = lock.withLock { roots }
        for r in copy.indices {
            let root = copy[r].path
            var touched = Set(
                paths.filter { FilePath.contains(path: $0, in: root) || FilePath.contains(path: root, in: $0) }
                    .map { Self.outsidePackages($0, root: root) })
            if touched.isEmpty { continue }
            if touched.count > 64 {
                // Many changes: their folders instead, walked again whole. Never the root for what changed directly in
                // it (a settings file saved in the home folder): that would walk the whole tree again for one file.
                touched = Set(
                    touched.map { p in
                        let folder = (p as NSString).deletingLastPathComponent
                        return p == root || folder == root ? p : folder
                    })
            }
            if rescan || touched.contains(copy[r].path) {
                let result = crawl(copy[r].path, config: config, generation: generation)
                copy[r] = Root(path: copy[r].path, base: result.table, holes: result.holes)
                continue
            }
            // Patches never overlap. A change inside an existing patch re-walks that patch.
            touched = Set(touched.map { p in copy[r].patches.first(where: { FilePath.contains(path: p, in: $0.path) })?.path ?? p })
            let top = touched.filter { p in !touched.contains { $0 != p && FilePath.contains(path: p, in: $0) } }
            for path in top where !excluded(path, config: config) {
                let result = crawl(path, config: config, generation: generation)
                copy[r].holes.removeAll { FilePath.contains(path: $0, in: path) }
                copy[r].holes.append(contentsOf: result.holes)
                copy[r].patches.removeAll { FilePath.contains(path: $0.path, in: path) }
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
    /// A change inside a package is a change of the folder holding it: walked from there, the package stays one
    /// entry, as in a full crawl (a walk starting inside it would index its contents).
    private static func outsidePackages(_ path: String, root: String) -> String {
        guard path != root, FilePath.contains(path: path, in: root) else { return path }
        var folder = root
        for name in path.dropFirst(root.count).split(separator: "/") {
            let next = (folder as NSString).appendingPathComponent(String(name))
            if (try? URL(fileURLWithPath: next).resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return folder }
            folder = next
        }
        return path
    }
    private func persist(_ config: IndexConfiguration, snapshot: [Root]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The folder is listed once (the first save, or after a failed one): files left by an older index go then.
            var saved = try savedFiles ?? Set(FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".idx") })
            savedFiles = nil
            var files: [RootFile] = []
            for root in snapshot {
                let base = root.file
                if !saved.contains(base) {
                    try root.base.write(to: directory.appendingPathComponent(base))
                    saved.insert(base)
                }
                var patches: [PatchFile] = []
                for patch in root.patches {
                    let file = patch.file
                    if !saved.contains(file) {
                        try patch.table.write(to: directory.appendingPathComponent(file))
                        saved.insert(file)
                    }
                    patches.append(PatchFile(path: patch.path, file: file, shadowed: patch.shadowed))
                }
                files.append(RootFile(path: root.path, base: base, patches: patches, holes: root.holes))
            }
            let manifest = Manifest(configuration: config, eventID: eventID, updated: Date(), roots: files)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            let keep = Set(files.flatMap { [$0.base] + $0.patches.map(\.file) })
            for file in saved.subtracting(keep) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
            savedFiles = keep
        } catch { lock.withLock { state.warning = "Index could not be saved: \(error.localizedDescription)" } }
    }
    private func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) } }

    /// nil means uncovered/not ready: caller must retain fd/ripgrep/Spotlight fallback.
    public func search(
        _ text: String, scope: URL, contents: Bool = false, limit: Int = 5000,
        cancelled: () -> Bool = { false }
    ) -> (paths: [String], snippets: [String: String], error: String?)? {
        do { return search(try SearchSpec(text, contents: contents), scope: scope, limit: limit, cancelled: cancelled) } catch {
            return ([], [:], error.localizedDescription)
        }
    }

    public func search(
        _ spec: SearchSpec, scope: URL, limit: Int = 5000, cancelled: () -> Bool = { false }
    ) -> (paths: [String], snippets: [String: String], error: String?)? {
        let contents = spec.contents, text = spec.text, query = spec.query
        let (config, snapshot, building) = lock.withLock { (current, roots, state.building) }
        let scope = FilePath.canonical(scope.path)
        let hasHoles = snapshot.flatMap(\.holes).contains { FilePath.contains(path: $0, in: scope) || FilePath.contains(path: scope, in: $0) }
        guard config.enabled, !building, !hasHoles, !excluded(scope, config: config),
            snapshot.contains(where: { FilePath.contains(path: scope, in: $0.path) && Self.sameVolume(scope, $0.path) }), !contents || config.content
        else { return nil }
        var found: [String] = [], snippets: [String: String] = [:]
        for root in snapshot where FilePath.contains(path: scope, in: root.path) || FilePath.contains(path: root.path, in: scope) {
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
                        guard !exclusions.contains(where: { FilePath.contains(path: p, in: $0) }), !found.contains(p),
                            let value = IndexFileText.read(p, limit: 5_000_000),
                            let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: {
                                spec.contentMatches(String($0))
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
