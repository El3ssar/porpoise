import Foundation

/// A Spotlight query that never holds up the main thread.
///
/// `NSMetadataQuery.start()` waits for Spotlight's server, and with Spotlight switched off (or its server stuck) it
/// doesn't return: started on the main thread, it froze the whole app. Queries run on a queue of their own instead,
/// and what they find reaches the main queue as lists of paths, in the query's order. One that hasn't finished
/// gathering within `timeout` reports `.unavailable` and is stopped.
final class SpotlightQuery: NSObject {
    enum Event {
        /// Part of the results while gathering.
        case progress([String])
        /// All results; with `live`, `.updated` follows whenever they change.
        case gathered([String])
        /// The results again, after items were added, removed or changed (`changed`: the changed ones).
        case updated([String], changed: Set<String>)
        /// Spotlight didn't answer in time.
        case unavailable
    }

    /// One queue for every query: a start that never returns holds up the later ones (which then time out), not
    /// one more thread each.
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.porpoise.spotlight"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    let query = NSMetadataQuery()
    private let limit: Int
    private let live: Bool
    private let timeout: TimeInterval
    private let handler: (Event) -> Void
    // Main queue only.
    private var gatheringDone = false
    private var stopped = false

    init(
        predicate: NSPredicate, scopes: [Any], sortedBy sort: [NSSortDescriptor] = [], limit: Int, live: Bool = false,
        timeout: TimeInterval = 5, handler: @escaping (Event) -> Void
    ) {
        self.limit = limit
        self.live = live
        self.timeout = timeout
        self.handler = handler
        super.init()
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = sort
        query.operationQueue = Self.queue
    }

    /// Starts the query; events arrive on the main queue until `stop()`.
    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(progressed), name: .NSMetadataQueryGatheringProgress, object: query)
        nc.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        if live { nc.addObserver(self, selector: #selector(updated), name: .NSMetadataQueryDidUpdate, object: query) }
        Self.queue.addOperation { [self] in
            if !query.start() { report(.unavailable, finishing: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.stopped, !self.gatheringDone else { return }
            self.stop()
            self.handler(.unavailable)
        }
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        Self.queue.addOperation { [query] in query.stop() }
    }

    // Notifications arrive on the query's queue, where its results may be read.

    @objc private func progressed() { report(.progress(paths()), finishing: false) }

    @objc private func gathered() {
        let found = paths()
        if !live { query.stop() }
        report(.gathered(found), finishing: true)
    }

    @objc private func updated(_ n: Notification) {
        let changed = ((n.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any]) ?? []).compactMap {
            ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
        report(.updated(paths(), changed: Set(changed)), finishing: false)
    }

    private func paths() -> [String] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        return (0..<min(query.resultCount, limit)).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
    }

    /// Hands `event` to the main queue, unless the query was stopped meanwhile. Gathering ends with `finishing`
    /// (`.gathered` or `.unavailable`); updates come only after it.
    private func report(_ event: Event, finishing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if case .updated = event { guard self.gatheringDone else { return } } else { guard !self.gatheringDone else { return } }
            if finishing { self.gatheringDone = true }
            self.handler(event)
        }
    }
}
