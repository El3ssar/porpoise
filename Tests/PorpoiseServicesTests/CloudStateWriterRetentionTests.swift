import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudStateWriterRetentionTests {
    @Test(.timeLimit(.minutes(1))) func anExplicitFlushForcesADeferredWriteInsteadOfLosingIt() async {
        // Forced-deadline behavior has its own test. Keep that timer outside this flush test's lifetime.
        let writer = CloudStateWriter(delay: 0, maximumDeferral: eventualTimeout * 2), attempts = Locked<[Bool]>([])
        let (deferred, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish() }
        writer.schedule("fixture") { force in
            attempts.append(force)
            if !force { signal.yield(()) }
            return force
        }
        var events = deferred.makeAsyncIterator()
        #expect(await events.next() != nil)
        #expect(attempts.value.first == false)
        await offThePool { writer.flush("fixture") }
        #expect(attempts.value == [false, true])
        await offThePool { writer.flushAll() }
        #expect(attempts.value == [false, true])
    }

    @Test(.timeLimit(.minutes(1))) func aDeferredWriteCanWakeWithoutWaitingOrAnotherMutation() async {
        let writer = CloudStateWriter(delay: 0, maximumDeferral: eventualTimeout * 2), attempts = Locked<[Bool]>([]), ready = Flag()
        let (changes, signal) = AsyncStream<Bool>.makeStream()
        defer { signal.finish() }
        writer.schedule("fixture") { force in
            attempts.append(force)
            let written = ready.isSet
            signal.yield(written)
            return written
        }
        var events = changes.makeAsyncIterator()
        #expect(await events.next() == false)
        ready.set(); writer.retry("fixture", after: 0)
        #expect(await events.next() == true)
        await offThePool { writer.flush("fixture") }
        #expect(attempts.value == [false, false])
    }

    private struct Item: CloudMetadataItem { let id: String }
    @Test func aMutationPersistsEvenWhilePlanningRemainsBusy() async throws {
        let scratch = try Scratch(), url = scratch.url.appendingPathComponent("state")
        let writer = CloudStateWriter(delay: 0, maximumDeferral: 0.05)
        let planning = Flag(), deferred = Flag(), contents = Locked("first")
        planning.set()
        let write: (Bool) -> Bool = { force in
            if planning.isSet && !force { deferred.set(); return false }
            try? Data(contents.value.utf8).write(to: url)
            return true
        }
        writer.schedule(url.path, write: write)
        await expectEventually("planning deferred the mutation") { deferred.isSet }
        contents.change { $0 = "latest" }
        writer.schedule(url.path, write: write)
        await expectEventually("maximum deferral forces the latest coalesced state") {
            (try? Data(contentsOf: url)) == Data("latest".utf8)
        }
        #expect(planning.isSet)
    }
    @Test func reopeningAnEnabledCacheStillFlushesItsLatestOwnedMetadata() async throws {
        let scratch = try Scratch()
        let cache = await offThePool { CloudMetadataCache<Item>(directory: scratch.url) }
        let items = (0..<1_000).map { Item(id: "\($0)") }
        cache.remember(items)
        let owner = cache.retainMetadata(.init(items: Set(items.map(\.id))))
        cache.enableRetention(.init(limits: .init(files: 0, listings: 0, bytes: 0)))
        let reopened = await offThePool { CloudMetadataCache<Item>(directory: scratch.url) }
        #expect(reopened.files.count == items.count)
        owner.release()
        await cache.settleRetention()
        #expect(cache.files.isEmpty)
    }
}
