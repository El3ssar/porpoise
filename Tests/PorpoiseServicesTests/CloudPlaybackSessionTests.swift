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
        let scratch = try Scratch(), invalid = try scratch.file("broken.mov", "not a movie"), session = CloudPlaybackSession()
        let opening: Bool = try await awaitCallback { callback in
            session.onStatus = { if case .unavailable(let error, let opening) = $0 { callback.resume(returning: opening && error is Fault) } }
            session.start { throw Fault.opening }
        }
        #expect(opening)
        let playing: Bool = try await awaitCallback { callback in
            session.onStatus = { if case .unavailable(_, let opening) = $0 { callback.resume(returning: !opening) } }
            session.onPlayer = { player, _ in player.play() }
            session.start { CloudPlayback(url: invalid) }
        }
        #expect(playing)
        session.stop()
    }

    @Test func cachedObservationAndBufferingPolicyRemainSelectable() async throws {
        let scratch = try Scratch(), invalid = try scratch.file("broken.mov", "not a movie")
        let session = CloudPlaybackSession(preferredForwardBufferDuration: 0, observesCached: false), statuses = Counter()
        let observation = Locked<NSKeyValueObservation?>(nil)
        session.onStatus = { _ in statuses.add() }
        try await awaitCallback { callback in
            session.onPlayer = { player, _ in
                observation.change {
                    $0 = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
                        if item.status == .failed { callback.resume() }
                    }
                }
                player.play()
            }
            session.start { CloudPlayback(url: invalid) }
        }
        #expect(session.player?.currentItem?.preferredForwardBufferDuration == 0 && statuses.value == 1)
        observation.change { $0 = nil }; session.stop()
    }

    @Test func releasingTheSessionStopsItsOwnedStream() async throws {
        let stream = Stream()
        var session: CloudPlaybackSession? = CloudPlaybackSession()
        weak var owner = session
        session?.start { CloudPlayback(url: stream.url, stream: stream) }
        await expectEventually { owner?.player != nil }
        session = nil
        await expectEventually { owner == nil && stream.stops.value == 1 }
    }

}
