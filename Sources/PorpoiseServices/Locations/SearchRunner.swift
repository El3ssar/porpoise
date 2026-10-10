import Foundation
import PorpoiseCore

/// Runs a search: Spotlight like Dolphin's Baloo search, with live results; where Spotlight finds nothing (hidden
/// and unindexed folders) or doesn't answer, the simple search walks the folders instead.
public final class SearchRunner: NSObject {
    private let update: ([FileItem], Bool) -> Void
    private let text: String
    private let scope: URL
    private let contents: Bool
    private var spotlight: SpotlightQuery?
    /// Cancellation token of the running simple search.
    private var fallbackWork: DispatchWorkItem?
    /// Results already read from disk (Spotlight reports the growing list again on every progress/update).
    private var loaded: [String: FileItem] = [:]

    /// How long Spotlight may take to gather before the simple search takes over.
    var gatheringTimeout: TimeInterval = 5
    /// Off: only the simple search (what tests of it use, whatever Spotlight indexes on the machine).
    var usesSpotlight = true

    private static let maxSpotlightResults = 5000
    private static let maxSimpleResults = 2000
    private static let maxSimpleVisited = 200_000
    /// Larger files are not searched for contents by the simple search.
    private static let maxContentSearchSize = 5_000_000

    public init(text: String, scope: URL, contents: Bool, update: @escaping ([FileItem], Bool) -> Void) {
        self.text = text
        self.scope = scope
        self.contents = contents
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
        guard usesSpotlight else { simpleSearch(); return }
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
        case .gathered(let paths) where paths.isEmpty: simpleSearch()
        case .gathered(let paths): publish(paths, done: true)
        case .updated(let paths, let changed):
            guard fallbackWork == nil else { return }
            // Changed files are read again; the others come from the cache.
            for p in changed { loaded[p] = nil }
            publish(paths, done: true)
        case .unavailable: simpleSearch()
        }
    }

    private func publish(_ paths: [String], done: Bool) {
        var items: [FileItem] = []
        var seen: [String: FileItem] = [:]
        for p in paths {
            // Each path is read from disk once (Spotlight reports the whole growing list every time).
            guard let it = loaded[p] ?? FileItem.load(URL(fileURLWithPath: p)) else { continue }
            seen[p] = it
            items.append(it)
        }
        loaded = seen
        update(items, done)
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
        fallbackWork?.cancel()
        loaded = [:]
    }
}
