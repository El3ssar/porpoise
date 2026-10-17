import AVFoundation
import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct CloudPlaybackSessionTests {
    private final class Stream: CloudPreviewStream {
        let url = URL(fileURLWithPath: "/fixture-not-media")
        let stops = Counter()
        func stop() { stops.add() }
    }
    private enum Fault: Error { case opening }

    @Test func aStreamReturnedAfterCancellationIsStoppedAndNeverPublished() async throws {
        let held = Locked<Callback<CloudPlayback>?>(nil), stream = Stream(), session = CloudPlaybackSession(), published = Counter()
        session.onPlayer = { _, _ in published.add() }
        session.start { try await awaitCallback { callback in held.change { $0 = callback } } }
        await expectEventually { held.value != nil }
        session.stop()
        held.value?.resume(returning: CloudPlayback(url: stream.url, stream: stream))
        await expectEventually { stream.stops.value == 1 }
        #expect(published.value == 0 && session.player == nil && !session.isStreaming)
    }

    @Test func aNewSelectionRejectsTheOldResultAndStopReleasesItsPlayerAndStream() async throws {
        let held = Locked<Callback<CloudPlayback>?>(nil), old = Stream(), current = Stream(), session = CloudPlaybackSession()
        let published = Counter()
        session.onPlayer = { _, _ in published.add() }
        session.start { try await awaitCallback { callback in held.change { $0 = callback } } }
        await expectEventually { held.value != nil }
        session.start { CloudPlayback(url: current.url, stream: current) }
        await expectEventually { session.player != nil }
        held.value?.resume(returning: CloudPlayback(url: old.url, stream: old))
        await expectEventually { old.stops.value == 1 }
        #expect(published.value == 1 && session.isStreaming)
        session.stop(); session.stop()
        #expect(current.stops.value == 1 && session.player == nil && !session.isStreaming)
    }

    @Test func loadingAndActualPlayerFailuresAreReportedWithTheirStage() async throws {
        let session = CloudPlaybackSession()
        var openingFailed = false, playingFailed = false
        session.onStatus = { status in
            if case .unavailable(let error, let opening) = status {
                if opening { openingFailed = error is Fault } else { playingFailed = true }
            }
        }
        session.start { throw Fault.opening }
        await expectEventually { openingFailed }
        session.start { CloudPlayback(url: URL(fileURLWithPath: "/fixture-missing-media-" + UUID().uuidString)) }
        await expectEventually { playingFailed }
        session.stop()
    }
}
