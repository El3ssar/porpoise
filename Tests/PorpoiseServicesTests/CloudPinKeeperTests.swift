import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudPinKeeperTests {
    @Test func keepsTwoHundredWithBoundedConcurrencyThenReconciles() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let folder = source.add("folder", folder: true)
        for n in 0..<200 { _ = source.add("file-\(n)", parent: "folder") }
        let store = try CloudOfflineStoreTests().store(source, scratch)
        let keeper = CloudPinKeeper(store: store)
        try await store.remember([folder]); try await store.pin([folder.ref])
        await keeper.reconcile()
        let snapshot = await store.snapshot()
        #expect(snapshot.entries.count == 200)
        #expect(source.downloads == 200 && source.maximum <= 2)
        for entry in snapshot.entries.values {
            #expect(try entry.item.checksum?.verify(store.directory.appendingPathComponent(entry.path)) == true)
        }
        let changed = source.add("file-1", parent: "folder", text: "new revision", revision: "r2")
        await keeper.apply(.init(changed: [changed]))
        #expect(await store.snapshot().entries["file-1"]?.item.revision == "r2")
        source.items["file-2"] = nil
        await keeper.apply(.init(removed: ["file-2"]))
        #expect(await store.snapshot().entries.count == 199)
        source.items["file-3"] = nil
        await keeper.apply(.init(reset: true))
        #expect(await store.snapshot().entries.count == 198)
        let count = try countFiles(store.directory.appendingPathComponent("objects"))
        #expect(count == 198)
        print("OFFLINE fixture: 200 verified, max concurrent \(source.maximum); revision replaced, trash/reset: 198 entries / \(count) files")
    }
    private func countFiles(_ root: URL) throws -> Int {
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var count = 0
        for case let url as URL in files where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        return count
    }
    @Test func movedOutBecomesRecentAndCyclesTerminate() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let folder = source.add("folder", parent: "nested", folder: true)
        _ = source.add("nested", parent: "folder", folder: true)
        let child = source.add("child", parent: "folder")
        let store = try CloudOfflineStoreTests().store(source, scratch)
        let keeper = CloudPinKeeper(store: store)
        try await store.remember([folder]); try await store.pin([folder.ref])
        await keeper.reconcile()
        #expect(await store.snapshot().usage.kept == 5)
        var moved = child; moved.parents = []; source.items["child"] = moved
        await keeper.apply(.init(changed: [moved]))
        #expect(await store.snapshot().usage.recent == 5)
        #expect(await store.snapshot().entries["child"] != nil)
        await keeper.resume(); await keeper.stop()
    }
}

extension CloudPinKeeperTests {
    @Test func resetWhileOfflinePreservesVerifiedBytes() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let item = source.add("one")
        let store = try CloudOfflineStoreTests().store(source, scratch)
        _ = try await store.fetch(item, keep: true)
        let keeper = CloudPinKeeper(store: store)
        source.isOffline = true
        await keeper.apply(.init(reset: true))
        #expect(await store.snapshot().entries.count == 1)
        source.isOffline = false
        await keeper.resume()
        #expect(source.downloads == 1)
        source.items["one"] = nil
        await keeper.apply(.init(reset: true))
        #expect(await store.snapshot().entries.isEmpty)
        await keeper.stop()
    }
}

extension CloudPinKeeperTests {
    @Test func aHeldRemovalDoesNotPreventOtherRemovals() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let held = source.add("held"), other = source.add("other")
        let store = try CloudOfflineStoreTests().store(source, scratch, held: { $0.item == "held" })
        _ = try await store.fetch(held, keep: true); _ = try await store.fetch(other, keep: true)
        let keeper = CloudPinKeeper(store: store)
        await keeper.apply(.init(removed: ["held", "other"]))
        #expect(await store.snapshot().entries["held"] != nil)
        #expect(await store.snapshot().entries["other"] == nil)
        await keeper.stop()
    }
}

extension CloudPinKeeperTests {
    /// Changes elsewhere in the account don't grow the index; changes under a kept folder, and to known items, do.
    /// Keeping a folder of 50 sends one snapshot per coalescing window, not one per change and progress report: the
    /// test holds the window open for the whole keep, so exactly one snapshot follows when it closes.
    @Test func changesOutsideKeptFoldersStayOutAndSnapshotsAreCoalesced() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let folder = source.add("folder", folder: true)
        for n in 0..<50 { _ = source.add("file-\(n)", parent: "folder") }
        let published = Counter(), window = PublishWindow()
        let store = try CloudOfflineStore(
            source: source, directory: scratch.url.appendingPathComponent("Offline"), recentLimit: nil,
            freeSpace: { (100_000_000_000, 200_000_000_000) }, changed: { _ in published.add() },
            publishPacing: { await window.wait() })
        let keeper = CloudPinKeeper(store: store)
        try await store.remember([folder]); try await store.pin([folder.ref])
        await keeper.reconcile()
        #expect(await store.snapshot().entries.count == 50)
        await expectEventually { window.waiting == 1 }
        #expect(published.value == 0)
        window.close()
        await expectEventually { published.value == 1 }
        #expect(window.closed == 1)
        let elsewhere = source.add("elsewhere", parent: "other"), added = source.add("added", parent: "folder")
        await keeper.apply(.init(changed: [elsewhere, added]))
        let snapshot = await store.snapshot()
        #expect(snapshot.items["elsewhere"] == nil && snapshot.entries["added"] != nil)
        await keeper.stop()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// Coalescing windows the test closes: each `wait` (one window) lasts until `close`, after which every later window
/// closes at once (so nothing is left suspended after the test).
private final class PublishWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ended = 0
    /// Windows still open.
    var waiting: Int { lock.withLock { waiters.count } }
    /// Windows that closed (`wait` returned).
    var closed: Int { lock.withLock { ended } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock {
                if isClosed { ended += 1; return true }
                waiters.append(c); return false
            }
            if now { c.resume() }
        }
    }
    func close() {
        let pending = lock.withLock {
            isClosed = true; ended += waiters.count
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume() }
    }
}
