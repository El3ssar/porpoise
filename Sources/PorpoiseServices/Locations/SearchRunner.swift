import Foundation
import PorpoiseCore

/// Runs a search: Spotlight (NSMetadataQuery) like Dolphin's Baloo search, with live results.
public final class SearchRunner: NSObject {
    let query = NSMetadataQuery()
    private let update: ([FileItem], Bool) -> Void
    private let text: String
    private let scope: URL
    private let contents: Bool
    /// Cancellation token of the running simple search.
    private var fallbackWork: DispatchWorkItem?
    /// Results already read from disk (Spotlight reports the growing list again on every progress/update).
    private var loaded: [String: FileItem] = [:]
    private var gatheringDone = false

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

    public func start() {
        let pattern = "*\(text)*"
        query.predicate = contents
            ? NSPredicate(format: "kMDItemTextContent LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@", pattern, pattern)
            : NSPredicate(format: "kMDItemFSName LIKE[cd] %@", pattern)
        query.searchScopes = [scope]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(progress), name: .NSMetadataQueryGatheringProgress, object: query)
        // Live results: files created, renamed or deleted while the results are shown.
        NotificationCenter.default.addObserver(self, selector: #selector(liveUpdate), name: .NSMetadataQueryDidUpdate, object: query)
        if !query.start() { simpleSearch() }
    }

    @objc private func progress() { publish(done: false) }

    @objc private func liveUpdate(_ n: Notification) {
        guard gatheringDone, fallbackWork == nil else { return }
        // Changed files are read again; the others come from the cache.
        for case let r as NSMetadataItem in (n.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any]) ?? [] {
            if let p = r.value(forAttribute: NSMetadataItemPathKey) as? String { loaded[p] = nil }
        }
        query.disableUpdates()
        publish(done: true)
        query.enableUpdates()
    }

    @objc private func gathered() {
        gatheringDone = true
        // Spotlight doesn't index hidden or excluded folders; Dolphin's simple search finds them. Without Spotlight
        // results it takes over (no "No items found" in between).
        if query.resultCount == 0 { simpleSearch(); return }
        query.disableUpdates()
        publish(done: true)
        query.enableUpdates()
    }

    private func publish(done: Bool) {
        var items: [FileItem] = []
        var seen: [String: FileItem] = [:]
        for i in 0..<min(query.resultCount, Self.maxSpotlightResults) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
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
                   let s = String(data: d, encoding: .utf8) { hit = s.lowercased().contains(needle) }
                if hit, let it = FileItem.load(u) { out.append(it) }
                if out.count >= Self.maxSimpleResults { break }
            }
            DispatchQueue.main.async { if !work.isCancelled { self?.update(out, true) } }
        }
    }

    public func stop() {
        query.stop()
        fallbackWork?.cancel()
        loaded = [:]
        NotificationCenter.default.removeObserver(self)
    }
}
