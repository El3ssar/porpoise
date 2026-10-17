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
