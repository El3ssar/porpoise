import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct IndexStartupConcurrencyTests {
    /// Held: an operation queue doesn't keep its underlying queue.
    private static let crawlThread = DispatchQueue(label: "IndexStartupConcurrencyTests.crawls", qos: .utility)

    /// A suspended stand-in for the index's crawl queue, on a serial queue of its own like the real one. On the shared
    /// pool its crawl got no thread while other tests kept every core busy (CI's 3-core runner), and the index never
    /// finished building (W-127).
    private static func crawlWorkers() -> OperationQueue {
        let workers = OperationQueue()
        workers.maxConcurrentOperationCount = 1
        workers.underlyingQueue = crawlThread
        workers.isSuspended = true
        return workers
    }

    @Test func fortyMultiRootIndexesReconfigureWhileOneWorkerPoolIsSuspended() async throws {
        let scratch = try Scratch()
        let workers = Self.crawlWorkers()
        var indexes: [SearchIndex] = []
        var configurations: [IndexConfiguration] = []
        var suites: [String] = []
        defer {
            indexes.forEach { $0.configure(IndexConfiguration()) }
            workers.isSuspended = false
            suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        }
        for n in 0..<40 {
            let suite = "IndexStartupStress.\(UUID())"; suites.append(suite)
            let defaults = try #require(UserDefaults(suiteName: suite))
            let index = SearchIndex(directory: scratch.path("store-\(n)"), defaults: defaults, crawlQueue: workers)
            indexes.append(index)
            var config = IndexConfiguration(); config.enabled = true
            config.roots = try ["a", "b"].map { part in
                let url = try scratch.file("old-\(n)/\(part)/old-key.txt", "old")
                return url.deletingLastPathComponent().path
            }
            index.configure(config)
            config.roots = try ["a", "b"].map { part in
                let url = try scratch.file("fresh-\(n)/\(part)/new-key.txt", "new")
                return url.deletingLastPathComponent().path
            }
            configurations.append(config)
        }
        try #require(await eventually { indexes.allSatisfy { $0.status.message == "Index queued for crawl" } })
        // No crawl job can run. A control queue that joins those jobs can never start this new generation.
        for (index, config) in zip(indexes, configurations) { index.configure(config) }
        try #require(await eventually { indexes.allSatisfy { $0.status.message == "Index queued for crawl" } })
        #expect(indexes.allSatisfy { $0.status.building && $0.status.updated == nil })
        workers.isSuspended = false
        // Forty crawls, one after another on one queue: on CI's busy runner that took over a minute.
        try #require(await eventually(300) { indexes.allSatisfy { !$0.status.building && $0.status.updated != nil } })
        for (n, index) in indexes.enumerated() {
            for root in configurations[n].roots {
                #expect(index.search("new-key", scope: URL(fileURLWithPath: root))?.paths.count == 1)
                #expect(index.search("old-key", scope: URL(fileURLWithPath: root))?.paths.isEmpty == true)
            }
            #expect(index.search("old-key", scope: scratch.path("old-\(n)/a")) == nil)
        }
    }

    @Test func eventsDuringSuspendedInitialCrawlStayBufferedUntilSnapshotIsReady() async throws {
        let scratch = try Scratch(); let root = try scratch.folder("root")
        let workers = Self.crawlWorkers()
        let suite = "IndexStartupEvents.\(UUID())"
        let index = SearchIndex(directory: scratch.path("store"), defaults: try #require(UserDefaults(suiteName: suite)), crawlQueue: workers)
        defer {
            index.configure(IndexConfiguration()); workers.isSuspended = false
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        var config = IndexConfiguration(); config.enabled = true; config.roots = [root.path]
        index.configure(config)
        try #require(await eventually { index.status.message == "Index queued for crawl" })
        try scratch.file("root/during-crawl.txt", "new")
        // A real FSEvent is consumed while the crawl cannot start. It must neither publish an empty index nor
        // advance the saved cursor past unapplied changes.
        try #require(await eventually { index.status.pendingChanges > 0 })
        #expect(index.status.building && index.status.updated == nil)
        #expect(index.search("during-crawl", scope: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.path("store/manifest.json").path))
        workers.isSuspended = false
        try #require(await eventually { !index.status.building && index.status.updated != nil })
        #expect(index.status.pendingChanges == 0)
        #expect(index.search("during-crawl", scope: root)?.paths.count == 1)
    }
}
