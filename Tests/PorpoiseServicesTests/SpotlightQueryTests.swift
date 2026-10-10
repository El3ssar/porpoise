import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Spotlight queries run off the main thread and give up when Spotlight doesn't answer. A Spotlight that never
/// answers is simulated by keeping the queries' queue busy, as a `start()` that never returns does.
@MainActor @Suite(.serialized) struct SpotlightQueryTests {
    /// Holds the Spotlight queue until the returned function is called.
    private func stallSpotlight() -> () -> Void {
        let release = DispatchSemaphore(value: 0)
        SpotlightQuery.queue.addOperation { _ = release.wait(timeout: .now() + 30) }
        return { release.signal() }
    }

    private func nothing(in scope: URL) -> NSPredicate { NSPredicate(format: "kMDItemFSName == %@", "none-\(UUID().uuidString)") }

    @Test func aQueryThatSpotlightNeverAnswersReportsUnavailableWithoutBlocking() async throws {
        let s = try Scratch()
        let resume = stallSpotlight()
        defer { resume() }
        var events: [String] = []
        let q = SpotlightQuery(predicate: nothing(in: s.url), scopes: [s.url], limit: 10, timeout: 0.3) { event in
            if case .unavailable = event { events.append("unavailable") } else { events.append("other") }
        }
        let started = Date()
        q.start()
        #expect(Date().timeIntervalSince(started) < 0.1)  // start() returned at once
        #expect(await eventually(5) { events == ["unavailable"] })
        resume()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(events == ["unavailable"])  // nothing more once it gave up
    }

    @Test func aStoppedQueryReportsNothing() async throws {
        let s = try Scratch()
        var events = 0
        let q = SpotlightQuery(predicate: nothing(in: s.url), scopes: [s.url], limit: 10, timeout: 0.3) { _ in events += 1 }
        q.start()
        q.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(events == 0)
    }

    @Test func searchFallsBackToWalkingTheFoldersWhenSpotlightNeverAnswers() async throws {
        let s = try Scratch()
        let tag = "porpoisestall\(UUID().uuidString.prefix(6))"
        try s.file("deep/down/\(tag).txt")
        let resume = stallSpotlight()
        defer { resume() }
        var result: [FileItem]?
        let runner = SearchRunner(text: tag, scope: s.url, contents: false) { items, done in if done { result = items } }
        runner.gatheringTimeout = 0.3
        runner.start()
        defer { runner.stop() }
        #expect(await eventually(10) { result != nil })
        #expect(result?.map(\.name) == ["\(tag).txt"])
    }

    @Test func recentFilesAndTagsAreEmptyWhenSpotlightNeverAnswers() async throws {
        let resume = stallSpotlight()
        defer { resume() }
        var tagged: [FileItem]?
        let q = MetadataListQuery.tagged("Red-\(UUID().uuidString)") { tagged = $0 }
        _ = q
        // Default timeout: Spotlight gets a few seconds before the list is shown empty.
        #expect(await eventually(10) { tagged != nil })
        #expect(tagged?.isEmpty == true)
    }
}
