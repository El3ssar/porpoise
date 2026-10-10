import Foundation
import PorpoiseCore

/// Runs a search. In a folder: the bundled fd and ripgrep, streaming results as they find them (hidden and
/// unindexed folders included). Everywhere: Spotlight, like Dolphin's Baloo search, with live results; where it finds
/// nothing or doesn't answer, the folders are searched as above. Without the tools, a simple walk of the folders.
public final class SearchRunner: NSObject {
    private let update: ([FileItem], Bool) -> Void
    private let text: String
    private let scope: URL
    private let contents: Bool
    private let everywhere: Bool
    private var spotlight: SpotlightQuery?
    private var folderSearch: FolderSearch?
    /// Cancellation token of the running simple search.
    private var fallbackWork: DispatchWorkItem?
    /// Results already read from disk (Spotlight reports the growing list again on every progress/update). Only
    /// touched on `loadQueue`: reading them on the main thread made typing in the search field stutter.
    private var loaded: [String: FileItem] = [:]
    private let loadQueue = DispatchQueue(label: "app.porpoise.search-results", qos: .userInitiated)
    /// The newest batch of Spotlight results; older ones still loading are dropped (main queue).
    private var generation = 0

    /// How long Spotlight may take to gather before the simple search takes over.
    var gatheringTimeout: TimeInterval = 5
    /// Off: only the simple search (what tests of it use, whatever Spotlight indexes on the machine).
    var usesSpotlight = true
    /// For the files found by their contents (in folders), the line that contains the text; current when `update`
    /// runs.
    public private(set) var snippets: [URL: String] = [:]
    /// The snippets name exactly the files found by contents only (the folders were searched with the tools).
    public var snippetsMarkContentMatches: Bool { folderSearch != nil }
    /// The tools that search folders (the bundled ones; tests choose).
    var folderTools = FolderSearch.tools

    private static let maxSpotlightResults = 5000
    private static let maxFolderResults = 5000
    private static let maxSimpleResults = 2000
    private static let maxSimpleVisited = 200_000
    /// Larger files are not searched for contents by the simple search.
    private static let maxContentSearchSize = 5_000_000

    /// `everywhere`: the scope is everything the user has (Spotlight's index); otherwise one folder.
    public init(text: String, scope: URL, contents: Bool, everywhere: Bool = false, update: @escaping ([FileItem], Bool) -> Void) {
        self.text = text
        self.scope = scope
        self.contents = contents
        self.everywhere = everywhere
        self.update = update
        super.init()
    }

    /// The Spotlight predicate for `text`: names, and with `contents` the text inside files too.
    static func predicate(_ text: String, contents: Bool) -> NSPredicate {
        let pattern = "*\(text)*"
        return contents
            ? NSPredicate(format: "kMDItemTextContent LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@", pattern, pattern)
            : NSPredicate(format: "kMDItemFSName LIKE[cd] %@", pattern)
    }

    public func start() {
        guard usesSpotlight, everywhere else { searchFolders(); return }
        let q = SpotlightQuery(
            predicate: Self.predicate(text, contents: contents), scopes: [scope], limit: Self.maxSpotlightResults, live: true,
            timeout: gatheringTimeout
        ) { [weak self] event in self?.handle(event) }
        spotlight = q
        q.start()
    }

    private func handle(_ event: SpotlightQuery.Event) {
        switch event {
        case .progress(let paths): publish(paths, done: false)
        // Spotlight doesn't index hidden or excluded folders; Dolphin's simple search finds them. Without Spotlight
        // results it takes over (no "No items found" in between).
        case .gathered(let paths) where paths.isEmpty: searchFolders()
        case .gathered(let paths): publish(paths, done: true)
        case .updated(let paths, let changed):
            guard fallbackWork == nil, folderSearch == nil else { return }
            publish(paths, done: true, changed: changed)
        case .unavailable: searchFolders()
        }
    }

    /// Reads Spotlight's paths into items off the main thread, then shows them (unless newer ones came meanwhile).
    private func publish(_ paths: [String], done: Bool, changed: Set<String> = []) {
        generation += 1
        let g = generation
        loadQueue.async { [weak self] in
            guard let self else { return }
            // Changed files are read again; each other path only once (Spotlight reports the whole list every time).
            for p in changed { self.loaded[p] = nil }
            var items: [FileItem] = []
            var seen: [String: FileItem] = [:]
            for p in paths {
                guard let it = self.loaded[p] ?? FileItem.load(URL(fileURLWithPath: p)) else { continue }
                seen[p] = it
                items.append(it)
            }
            self.loaded = seen
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.update(items, done)
            }
        }
    }

    /// The folder itself searched: with the bundled tools, else walked.
    private func searchFolders() {
        guard let tools = folderTools else { return simpleSearch() }
        let s = FolderSearch(text: text, scope: scope, contents: contents, limit: Self.maxFolderResults, tools: tools) {
            [weak self] items, snippets, done in
            self?.snippets = snippets
            self?.update(items, done)
        }
        folderSearch = s
        s.start()
    }

    /// Dolphin's "Simple search" (filenamesearch:/): walks the folder tree.
    private func simpleSearch() {
        let needle = text.lowercased()
        let scope = scope
        let contents = contents
        fallbackWork?.cancel()
        let work = DispatchWorkItem {}
        fallbackWork = work
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out: [FileItem] = []
            let e = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
            var n = 0
            while let u = e?.nextObject() as? URL {
                if work.isCancelled { return }
                n += 1
                if n > Self.maxSimpleVisited { break }
                var hit = u.lastPathComponent.lowercased().contains(needle)
                if !hit && contents, let d = try? Data(contentsOf: u, options: .mappedIfSafe), d.count < Self.maxContentSearchSize,
                    let s = String(data: d, encoding: .utf8)
                {
                    hit = s.lowercased().contains(needle)
                }
                if hit, let it = FileItem.load(u) { out.append(it) }
                if out.count >= Self.maxSimpleResults { break }
            }
            DispatchQueue.main.async { if !work.isCancelled { self?.update(out, true) } }
        }
    }

    public func stop() {
        spotlight?.stop()
        spotlight = nil
        folderSearch?.stop()
        folderSearch = nil
        generation += 1
        fallbackWork?.cancel()
        loadQueue.async { [weak self] in self?.loaded = [:] }
    }
}
