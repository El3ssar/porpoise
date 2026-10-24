import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudChangeFeedTests {
    @Test func transientPollingBacksOffAndRevocationStopsUntilRestart() async throws {
        let cursors = Locked(["user": "start"]), requests = Counter(), delays = Locked<[TimeInterval]>([])
        var adapter = source(cursors: cursors) { _, _ in .init(cursor: "next", hasMore: false, apply: {}) }
        adapter.wait = {
            requests.add()
            if requests.value <= 9 { throw Fault.transport }
            throw BoxError.reconnect
        }
        let feed = CloudChangeFeed(source: adapter, wait: { delays.append($0) })
        await feed.start()
        await expectEventually { requests.value == 10 }
        #expect(delays.value == [5, 10, 20, 40, 80, 160, 300, 300, 300])
        await feed.stop()
        await feed.start()  // Explicit sign-in/start may try again; no timer retries a terminal grant by itself.
        await expectEventually { requests.value == 11 }
        #expect(delays.value.count == 9)
        await feed.stop()
    }
    private enum Fault: Error, Equatable { case transport, reset, invalid }
    private func source(
        scopes: [String] = ["user"], cursors: Locked<[String: String]>,
        page: @escaping (String, String?) async throws -> CloudChangePage
    ) -> CloudChangeSource {
        CloudChangeSource(
            scopes: { scopes }, cursor: { cursors.value[$0] },
            setCursor: { token, scope in cursors.change { $0[scope] = token } }, initialize: { _ in "start" }, page: page,
            isReset: { ($0 as? Fault) == .reset }, reset: { scope in cursors.change { $0[scope] = nil } },
            waitNeedsCursor: false, wait: { .init(changes: false, backoff: 30) }, invalidPage: Fault.invalid)
    }

    private struct Item: CloudMetadataItem { let id: String; var name: String }
    @Test func staleRemovalsKeepNewerLocalMutationsAndCurrentRemovalsApply() throws {
        let scratch = try Scratch(), cache = CloudMetadataCache<Item>(directory: scratch.url)
        let old = Item(id: "opaque", name: "old")
        cache.store([old], key: "folder"); let since = cache.generation
        cache.remember([Item(id: old.id, name: "local rename")])
        let stale = cache.apply([], removed: [old.id], belongs: { _, _ in false }, since: since)
        #expect(stale.isEmpty && cache.file(old.id)?.name == "local rename")
        #expect(cache.snapshot("folder")?.files.map(\.id) == [old.id])
        let current = cache.apply([], removed: [old.id], belongs: { _, _ in false }, since: cache.generation)
        #expect(current == [old.id] && cache.file(old.id) == nil && cache.snapshot("folder")?.files.isEmpty == true)
    }

    @Test(arguments: [false, true]) func concurrentChecksShareCompletionAndErrors(_ fails: Bool) async throws {
        let cursors = Locked(["user": "start"]), requests = Counter(), applied = Counter(), joined = Flag()
        let release = Locked<Callback<Void>?>(nil)
        var adapter = source(cursors: cursors) { _, _ in
            requests.add()
            try await awaitCallback("release held change page") { callback in release.change { $0 = callback } }
            if fails { throw Fault.transport }
            return CloudChangePage(cursor: "next", hasMore: false, apply: { applied.add() })
        }
        adapter.joinedCheck = { joined.set() }
        let feed = CloudChangeFeed(source: adapter), first = Task { try await feed.check() }
        defer { release.value?.resume() }
        await expectEventually("first request held") { release.value != nil }
        let second = Task { try await feed.check() }
        await expectEventually("second check joined") { joined.isSet }
        #expect(requests.value == 1 && applied.value == 0 && cursors.value["user"] == "start")
        if !fails { second.cancel() }  // A cancelled waiter does not cancel the shared provider request.
        release.value?.resume()
        if fails {
            await #expect(throws: Fault.transport) { try await first.value }
            await #expect(throws: Fault.transport) { try await second.value }
            #expect(applied.value == 0 && cursors.value["user"] == "start")
        } else {
            try await first.value; try await second.value
            #expect(applied.value == 1 && cursors.value["user"] == "next")
        }
    }

    @Test func stopDrainsTheRequestBeforeCacheWipeAndPreventsLateApply() async throws {
        let cursors = Locked(["user": "start"]), cancelled = Flag(), stopped = Flag(), applied = Counter()
        let release = Locked<Callback<Void>?>(nil)
        let adapter = source(cursors: cursors) { _, _ in
            try await withTaskCancellationHandler {
                try await awaitCallback("release cancelled request") { callback in release.change { $0 = callback } }
            } onCancel: {
                cancelled.set()
            }
            return CloudChangePage(cursor: "late", hasMore: false, apply: { applied.add() })
        }
        let feed = CloudChangeFeed(source: adapter), checking = Task { try await feed.check() }
        defer { release.value?.resume() }
        await expectEventually("request held") { release.value != nil }
        let stop = Task {
            await feed.stop(); stopped.set()
        }
        await expectEventually("request cancellation observed") { cancelled.isSet }
        #expect(!stopped.isSet && applied.value == 0)
        release.value?.resume(); await stop.value
        await #expect(throws: CancellationError.self) { try await checking.value }
        #expect(stopped.isSet && applied.value == 0 && cursors.value["user"] == "start")
    }

    @Test func stopAlsoDrainsAnExplicitLongPollBeforeItCanStartAnotherCheck() async throws {
        let release = Locked<Callback<Void>?>(nil), cancelled = Flag(), stopped = Flag(), pages = Counter()
        var adapter = source(cursors: Locked(["user": "start"])) { _, _ in
            pages.add(); return CloudChangePage(cursor: "late", hasMore: false, apply: {})
        }
        adapter.wait = {
            try await withTaskCancellationHandler {
                try await awaitCallback { callback in release.change { $0 = callback } }
            } onCancel: {
                cancelled.set()
            }
            return CloudChangePoll(changes: true, backoff: 0)
        }
        let feed = CloudChangeFeed(source: adapter), polling = Task { try await feed.pollOnce() }
        defer { release.value?.resume() }
        await expectEventually("long poll held") { release.value != nil }
        let stop = Task {
            await feed.stop(); stopped.set()
        }
        await expectEventually("long poll cancellation observed") { cancelled.isSet }
        #expect(!stopped.isSet && pages.value == 0)
        release.value?.resume(); await stop.value
        await #expect(throws: CancellationError.self) { try await polling.value }
        #expect(stopped.isSet && pages.value == 0)
    }

    @Test func resetContinuesOtherScopesAndLoopsAreBounded() async throws {
        let cursors = Locked(["user": "old", "shared": "old"]), calls = Locked<[String]>([]), applied = Locked<[String]>([])
        let feed = CloudChangeFeed(
            source: source(scopes: ["user", "shared"], cursors: cursors) { scope, _ in
                calls.append(scope)
                if calls.value.count == 1 { throw Fault.reset }
                return CloudChangePage(cursor: scope + "-next", hasMore: false, apply: { applied.append(scope) })
            })
        try await feed.check()
        #expect(calls.value == ["user", "user", "shared"] && applied.value == ["user", "shared"])
        #expect(cursors.value == ["user": "user-next", "shared": "shared-next"])
        let resets = Counter()
        let broken = CloudChangeFeed(
            source: source(cursors: Locked([:])) { _, _ in
                resets.add(); throw Fault.reset
            })
        await #expect(throws: Fault.invalid) { try await broken.check() }
        #expect(resets.value == 2)
        let pages = Counter()
        let looping = CloudChangeFeed(
            source: source(cursors: Locked([:])) { _, _ in
                pages.add(); return CloudChangePage(cursor: "same", hasMore: true, apply: {})
            })
        await #expect(throws: Fault.invalid) { try await looping.check() }
        #expect(pages.value == 2)
    }
}
