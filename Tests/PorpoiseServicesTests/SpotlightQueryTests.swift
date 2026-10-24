import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Spotlight queries run off the main thread and give up when Spotlight doesn't answer. A Spotlight that never
/// answers is simulated by keeping the queries' queue busy, as a `start()` that never returns does.
@MainActor @Suite(.serialized) struct SpotlightQueryTests {
    private func nothing(in scope: URL) -> NSPredicate { NSPredicate(format: "kMDItemFSName == %@", "none-\(UUID().uuidString)") }

    @Test func aQueryThatSpotlightNeverAnswersReportsUnavailableWithoutBlocking() async throws {
        let s = try Scratch()
        let resume = stallSpotlight()
        defer { resume() }
        // Queued behind the stall (the queue runs one operation at a time, in order): it runs only once Spotlight
        // "answers".
        let pastStall = Locked(false)
        SpotlightQuery.queue.addOperation { pastStall.change { $0 = true } }
        var events: [String] = []
        let q = SpotlightQuery(predicate: nothing(in: s.url), scopes: [s.url], limit: 10, timeout: 0.3) { event in
            if case .unavailable = event { events.append("unavailable") } else { events.append("other") }
        }
        q.start()
        #expect(!pastStall.value)  // start() returned while Spotlight still hadn't answered: it didn't wait for it
        #expect(await eventually { events == ["unavailable"] })
        resume()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(events == ["unavailable"])  // nothing more once it gave up
    }

    @Test func metadataReadsRunOffMainAndCancellationDropsDelivery() async throws {
        let s = try Scratch(), url = try s.file("file.txt")
        let files = MetadataFileLoad()
        let onMain = Locked([Bool]())
        var listed: LocationListing?
        files.start(
            [url],
            load: { url in
                onMain.append(Thread.isMainThread); return FileItem.load(url)
            }
        ) { listed = $0 }
        #expect(await eventually { listed != nil })
        #expect(onMain.value == [false] && listed?.items.map(\.url) == [url])
        let canceled = MetadataFileLoad()
        canceled.cancel()
        canceled.start(
            [url],
            load: { _ in
                Issue.record("Canceled metadata must not read"); return nil
            }
        ) { _ in
            Issue.record("Canceled metadata must not deliver")
        }
        try await Task.sleep(for: .milliseconds(50))
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
        #expect(await eventually { result != nil })
        #expect(result?.map(\.name) == ["\(tag).txt"])
    }

    @Test(.timeLimit(.minutes(5))) func recentFilesAndTagsReportFailureWhenSpotlightNeverAnswers() async throws {
        let resume = stallSpotlight()
        defer { resume() }
        let source = SpotlightListSource(location: FinderTags.url(for: "Red-\(UUID().uuidString)"))
        var load: LocationLoad?
        defer { load?.cancel() }
        let tagged: LocationListing = try await awaitCallback { continuation in
            load = source.load(source.location, expanded: []) { continuation.resume(returning: $0) }
        }
        #expect(tagged.error != nil && tagged.items.isEmpty)

    }
}
