import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudMetadataCacheRetentionTests {
    private final class Item: CloudMetadataItem {
        let id: String
        let name: String
        let parent: String?
        let payload: String
        init(_ id: String, name: String = "name", parent: String? = nil) {
            self.id = id; self.name = name; self.parent = parent
            payload = String(repeating: "x", count: 256)
        }
    }
    private func cache(_ scratch: Scratch) async -> CloudMetadataCache<Item> {
        await offThePool { CloudMetadataCache<Item>(directory: scratch.url) }
    }
    private func configuration(files: Int = 0, listings: Int = 0) -> CloudMetadataCache<Item>.RetentionConfiguration {
        .init(limits: .init(files: files, listings: listings, bytes: 1_000_000), parents: { Set($0.parent.map { [$0] } ?? []) })
    }

    @Test func ordinaryBrowsingReleasesItemsSnapshotsAndBookkeeping() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.enableRetention(configuration(files: 200, listings: 4))
        weak var first: Item?
        for page in 0..<50 {
            let items = (0..<100).map { Item("\(page)-\($0)") }
            if page == 0 { first = items.first }
            cache.store(items, key: "folder-\(page)")
            cache.setCursor("cursor", scope: "listing:folder-\(page)")
        }
        await cache.settleRetention()
        await offThePool { cache.flush() }
        #expect(cache.files.count <= 200 && first == nil)
        let accounting = try #require(cache.retentionAccounting)
        #expect(accounting.ordinaryFiles <= 200 && accounting.ordinaryListings <= 4 && accounting.ordinaryBytes <= 1_000_000)
        #expect(cache.retentionStorageCounts.files <= 200 && cache.retentionStorageCounts.listings <= 4)
        let reopened = await offThePool { CloudMetadataCache<Item>(directory: scratch.url) }
        #expect(reopened.files.count <= 200)
        for page in 0..<50 {
            let key = "folder-\(page)"
            if let snapshot = cache.snapshot(key) {
                #expect(snapshot.files.count == 100)
            } else {
                #expect(reopened.snapshot(key) == nil && reopened.cursor("listing:" + key) == nil)
            }
        }
    }

    @Test func anOlderReadRetainsNewerMutationsThroughPruningAndDeferredApply() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.enableRetention(configuration())
        let read = cache.beginRead()
        cache.remember([Item("edited", name: "new")])
        cache.learn((0..<100).map { Item("ordinary-\($0)") }, since: cache.generation)
        await cache.settleRetention()
        #expect(cache.file("edited")?.name == "new" && cache.files.count == 1)
        let apply = { [read] in cache.store([Item("edited", name: "old")], key: "folder", since: read.generation) }
        apply()
        #expect(cache.snapshot("folder")?.files.first?.name == "new")
        await cache.settleRetention()
        #expect(cache.file("edited")?.name == "new")
        read.release()
        await cache.settleRetention()
        #expect(cache.file("edited") == nil && cache.retentionStorageCounts.reads == 0 && cache.retentionStorageCounts.remembered == 0)
    }

    @Test func snapshotInstallsDependencyContextAtomicallyWithoutUndoingNewerMetadata() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        var config = configuration()
        config.dependencies = { $0.id == "shortcut" ? ["target"] : [] }
        cache.enableRetention(config)
        let active = cache.retainMetadata(.init(listings: ["folder"]))
        let read = cache.beginRead()
        cache.remember([Item("target", name: "new", parent: "parent")])
        cache.store(
            [Item("shortcut")], key: "folder", since: read.generation,
            contextFiles: [Item("target", name: "old", parent: "parent"), Item("parent")], snapshotValue: nil)
        read.release()
        await cache.settleRetention()
        #expect(cache.snapshot("folder")?.files.map(\.id) == ["shortcut"])
        #expect(cache.file("target")?.name == "new" && cache.file("parent") != nil)
        active.release()
        await cache.settleRetention()
        #expect(cache.files.isEmpty && cache.snapshot("folder") == nil)
    }

    @Test func restoredOfflineSubtreeSurvivesBeforeTheFirstPrune() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.remember([Item("root"), Item("folder", parent: "root"), Item("child", parent: "folder"), Item("ordinary")])
        cache.alias("", to: Item("root"))
        cache.store([Item("child", parent: "folder")], key: "folder")
        let offMain = Locked(false)
        cache.enableRetention(configuration()) {
            offMain.change { $0 = !Thread.isMainThread }
            return ["offline": .init(owner: .init(subtrees: ["folder"]))]
        }
        await cache.settleRetention()
        #expect(offMain.value)
        #expect(cache.snapshot("folder")?.files.map(\.id) == ["child"])
        #expect(cache.file("child") != nil && cache.file("folder") != nil && cache.file("root") != nil && cache.file("") != nil)
        #expect(cache.file("ordinary") == nil)
        cache.setRetentionOwner("offline", nil)
        await cache.settleRetention()
        #expect(cache.snapshot("folder") == nil && cache.file("child") == nil && cache.file("folder") == nil)
        #expect(cache.file("") != nil && cache.file("root") != nil)
    }

    @Test func aLiveOwnerWinsOverAnOlderBootstrapAndEditRecordsSeedMissingMetadata() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.remember([Item("old")])
        cache.enableRetention(configuration()) {
            cache.setRetentionOwner("edits", .init(owner: .init(items: ["live"]), files: [Item("live", name: "edit")]))
            return ["edits": .init(owner: .init(items: ["old"]), files: [Item("old")])]
        }
        await cache.settleRetention()
        #expect(cache.file("live")?.name == "edit" && cache.file("old") == nil)
        cache.remember([Item("live", name: "newer")])
        cache.setRetentionOwner("edits", .init(owner: .init(items: ["live"]), files: [Item("live", name: "older session")]))
        await cache.settleRetention()
        #expect(cache.file("live")?.name == "newer")
    }

    @Test func unknownOwnershipConservativelyHoldsLoadedMetadataWithoutHoldingNewOrdinaryItems() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.remember([Item("loaded")])
        cache.enableRetention(configuration()) { ["offline": .init(owner: .init(), complete: false)] }
        await cache.settleRetention()
        cache.learn([Item("new ordinary")], since: cache.generation)
        await cache.settleRetention()
        #expect(cache.file("loaded") != nil && cache.file("new ordinary") == nil && cache.retentionRestoreFailures == 1)
        cache.setRetentionOwner("offline", .init(owner: .init()))
        await cache.settleRetention()
        #expect(cache.file("loaded") == nil && cache.retentionRestoreFailures == 0)
    }

    @Test func releasedLeasesAndInvalidatedListingsDoNotAccumulateAuxiliaryEntries() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.enableRetention(configuration())
        await cache.settleRetention()
        for i in 0..<500 {
            let lease = cache.retainMetadata(.init(items: ["unknown-\(i)"]))
            lease.release(); lease.release()
            cache.store([], key: "folder-\(i)")
            cache.invalidate("folder-\(i)")
            cache.setCursor("unused", scope: "listing:folder-\(i)")
        }
        await cache.settleRetention()
        #expect(cache.retentionStorageCounts.ownerVersions == 0 && cache.retentionStorageCounts.listings == 0)
        #expect(cache.retentionAccounting?.ownerReferences == 0)
        #expect((0..<500).allSatisfy { cache.cursor("listing:folder-\($0)") == nil })
    }

    @Test func aLeaseReleasedByDerivedValueInvalidationDoesNotReenterTheCacheLock() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.enableRetention(configuration())
        cache.remember([Item("held")])
        var lease: CloudMetadataLease? = cache.retainMetadata(.init(items: ["held"]))
        _ = cache.derived("lease-holder") { _ in lease! }
        lease = nil
        // persist() destroys the derived lease while holding the cache lock. Its cleanup must be asynchronous.
        await offThePool { cache.remember([Item("other")]) }
        await cache.settleRetention()
        #expect(cache.file("held") == nil && cache.retentionAccounting?.ownerReferences == 0)
    }

    @Test func aliasCanonicalInsertionOnlyOccursWhenRetentionIsEnabled() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.alias("legacy-alias", to: Item("legacy"))
        #expect(cache.file("legacy-alias")?.id == "legacy" && cache.file("legacy") == nil)
        cache.enableRetention(configuration())
        cache.alias("new-alias", to: Item("new"))
        await cache.settleRetention()
        #expect(cache.file("new-alias")?.id == "new" && cache.file("new")?.id == "new")
    }

    @Test(.timeLimit(.minutes(1))) func aContinuousWriterDoesNotPreventOrdinaryEviction() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.remember([Item("root")])
        cache.learn((0..<10_000).map { Item("ordinary-\($0)") }, since: cache.generation)
        let stop = Flag(), ended = Flag(), writes = Locked(0)
        let (progress, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (completion, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { stop.set(); signal.finish(); finished.finish() }
        Thread {
            defer { ended.set(); finished.yield(()); finished.finish() }
            var reported = false
            while !stop.isSet {
                let count = writes.change {
                    $0 += 1; return $0
                }
                cache.remember([Item("root", name: "update-\(count)")])
                // Observe progress on the writer itself; a busy cooperative pool cannot miss the event.
                if !reported, count % 50 == 0, cache.files.count <= 101 {
                    reported = true; signal.yield(()); signal.finish()
                }
                // A stream of writes, not a readiness assumption or a latency assertion.
                Thread.sleep(forTimeInterval: 0.001)
            }
        }.start()
        var config = configuration(files: 100)
        config.roots = ["root"]
        cache.enableRetention(config)
        var events = progress.makeAsyncIterator()
        #expect(await events.next() != nil)
        #expect(writes.value > 1 && cache.files.count <= 101 && !stop.isSet && !ended.isSet)
        stop.set()
        var end = completion.makeAsyncIterator()
        #expect(await end.next() != nil && ended.isSet)
        await cache.settleRetention()
        #expect(cache.files.count <= 101 && cache.file("root") != nil)
    }

    @Test func cachedCostsFollowChangedCanonicalAndSnapshotPayloads() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        var config = configuration(files: 10, listings: 10)
        config.limits.bytes = 2_000
        cache.enableRetention(config)
        cache.store([Item("a")], key: "folder")
        await cache.settleRetention()
        #expect(cache.snapshot("folder") != nil)
        _ = cache.apply([Item("a", name: String(repeating: "x", count: 10_000))], removed: [], belongs: { _, _ in true })
        cache.learn([Item("a")], since: cache.generation)
        await cache.settleRetention()
        // The canonical record is small again; only the old snapshot owns the large payload.
        #expect(cache.snapshot("folder") == nil && cache.file("a") != nil)
        cache.learn([Item("a", name: String(repeating: "x", count: 10_000))], since: cache.generation)
        await cache.settleRetention()
        #expect(cache.file("a") == nil && cache.retentionAccounting?.ordinaryBytes == 0)
    }

    private final class Rows {
        let onRelease: () -> Void
        init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        deinit { onRelease() }
    }
    @Test func snapshotAttachedRowsAreReleasedOutsideTheReaderLock() async throws {
        let scratch = try Scratch(), cache = await cache(scratch), released = Flag()
        cache.enableRetention(configuration())
        let owner = cache.retainMetadata(.init(listings: ["folder"]))
        weak var weakRows: Rows?
        do {
            let rows = Rows {
                _ = cache.file("a"); released.set()
            }
            weakRows = rows
            cache.store([Item("a")], key: "folder", since: nil, snapshotValue: ("rows", rows))
        }
        await cache.settleRetention()
        #expect(weakRows != nil)
        owner.release()
        await cache.settleRetention()
        #expect(weakRows == nil && released.isSet)
        let rows: Rows? = cache.snapshotValue("folder", name: "rows")
        #expect(rows == nil && cache.file("a") == nil)
    }

    @Test func freshnessMarkersDistinguishDiskMetadataAndEvictWithTheirRecords() async throws {
        let scratch = try Scratch(), cache = await cache(scratch)
        cache.remember([Item("a")])
        await offThePool { cache.flush() }
        let reopened = await offThePool { CloudMetadataCache<Item>(directory: scratch.url) }
        reopened.trackFreshMetadata()
        #expect(reopened.file("a") != nil && reopened.recentFile("a") == nil)
        reopened.remember([Item("a", name: "new")])
        #expect(reopened.recentFile("a")?.name == "new")
        reopened.enableRetention(configuration())
        await reopened.settleRetention()
        #expect(reopened.file("a") == nil && reopened.retentionStorageCounts.fresh == 0)
    }
}
