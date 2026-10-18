import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Index watchers and crawls end while their callbacks or readers may still be running: nothing may outlive them.
@Suite struct IndexLifecycleStressTests {
    /// A watcher freed while FSEvents is calling it back (changes keep coming) must not be touched afterwards.
    @Test func watchersFreedWhileEventsArriveDoNotCrash() async throws {
        let s = try Scratch()
        let root = try s.folder("root")
        let stop = Flag()
        let writer = Thread {
            var n = 0
            while !stop.isSet {
                try? Data("x".utf8).write(to: root.appendingPathComponent("f\(n % 50)"))
                n += 1
            }
        }
        writer.start()
        defer { stop.set() }
        // The writes reach a watcher (FSEvents can take seconds on a busy machine).
        let seen = Counter()
        let first = IndexEvents(roots: [root.path], since: 0) { _, _, _ in seen.add() }
        #expect(await eventually { seen.value > 0 })
        _ = first
        let calls = Counter()
        for _ in 0..<100 {
            var events: IndexEvents? = IndexEvents(roots: [root.path], since: 0) { _, _, _ in calls.add() }
            #expect(events?.available == true)
            // Freed on another thread, as SearchIndex does on its own queue, while callbacks may be running.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 0...30))) {
                    events = nil
                    c.resume()
                }
            }
        }
    }

    /// A big tree (readers on several threads) crawled and cancelled at random moments: the crawl returns with
    /// nothing left holding its caller's closures, and an uncancelled crawl lists everything.
    @Test func crawlsCancelledMidWalkReturnCleanly() throws {
        let s = try Scratch()
        for d in 0..<60 {
            let folder = try s.folder("root/d\(d)")
            for f in 0..<60 { FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(f)").path, contents: nil) }
        }
        let root = s.path("root").path
        #expect(IndexCrawler.crawl(root, exclusions: []).count == 1 + 60 + 60 * 60)
        for i in 0..<60 {
            let calls = Counter()
            let stopAfter = (i * 37) % 400
            let table = IndexCrawler.crawl(
                root, exclusions: [],
                cancelled: {
                    calls.add()
                    return calls.value > stopAfter
                }, skip: { _ in false })
            #expect(table.count <= 1 + 60 + 60 * 60)
        }
    }

}
