import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudMetadataRetentionPolicyTests {
    typealias Policy = CloudMetadataRetention

    @Test func ordinaryFilesUseLRUAndByteLimits() {
        var policy = Policy()
        for id in ["a", "b", "c"] { policy.putFile(id, bytes: 10) }
        policy.touchFile("a")
        #expect(policy.prune(to: .init(files: 2, listings: 4, bytes: 20)) == .init(files: ["b"]))
        #expect(policy.accounting.ordinaryFiles == 2 && policy.accounting.ordinaryBytes == 20)
        policy.putFile("oversized", bytes: 100)
        #expect(policy.prune(to: .init(files: 2, listings: 4, bytes: 20)).files == ["a", "c", "oversized"])
        #expect(policy.accounting.bytes == 0)
    }

    @Test func listingsAreEvictedWholeAndMembersStayAddressable() {
        var policy = Policy()
        for id in ["a", "b", "c"] { policy.putFile(id, bytes: 10) }
        policy.putListing("one", items: ["a", "b"], bytes: 20)
        policy.putListing("two", items: ["b", "c"], bytes: 20)
        policy.touchListing("one")
        let evicted = policy.prune(to: .init(files: 2, listings: 1, bytes: 40))
        #expect(evicted == .init(files: ["c"], listings: ["two"]))
        #expect(
            policy.accounting
                == .init(files: 2, listings: 1, bytes: 40, protectedFiles: 0, protectedListings: 0, protectedBytes: 0, owners: 0, ownerReferences: 0))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(files: ["a", "b"], listings: ["one"]))
    }

    @Test func snapshotCopiesCountAgainstTheByteBudget() {
        var policy = Policy()
        policy.putFile("a", bytes: 10)
        policy.putListing("one", items: ["a"], bytes: 100)
        policy.putListing("two", items: ["a"], bytes: 100)
        let evicted = policy.prune(to: .init(files: 10, listings: 10, bytes: 110))
        #expect(evicted == .init(listings: ["one"]))
        #expect(policy.accounting.bytes == 110)
        // Both snapshots referenced the same canonical item: dropping the first must not drop that item.
        #expect(policy.accounting.files == 1)
    }

    @Test func ownersProtectAliasesAncestorsSubtreesAndCycles() {
        var policy = Policy()
        policy.putFile("root", aliases: [""], bytes: 10)
        policy.putFile("folder", parents: [""], bytes: 10)
        policy.putFile("child", parents: ["folder"], bytes: 10)
        policy.putFile("grandchild", parents: ["child"], bytes: 10)
        policy.putFile("unrelated", bytes: 10)
        policy.putFile("cycle-a", parents: ["cycle-b"], bytes: 10)
        policy.putFile("cycle-b", parents: ["cycle-a"], bytes: 10)
        policy.setOwner("offline", .init(subtrees: ["folder"]))
        policy.setOwner("edit", .init(items: ["cycle-a"]))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["unrelated"])
        #expect(policy.accounting.protectedFiles == 6 && policy.accounting.protectedBytes == 60)
        #expect(policy.accounting.owners == 2 && policy.accounting.ownerReferences == 2)
        policy.setOwner("offline", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["root", "folder", "child", "grandchild"])
        policy.setOwner("edit", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["cycle-a", "cycle-b"])
        #expect(policy.accounting.files == 0 && policy.accounting.owners == 0)
    }

    @Test func activeListingProtectionIsAdditiveAndOwnerReplacementReleasesIt() {
        var policy = Policy()
        policy.putFile("root", bytes: 10)
        policy.putFile("a", parents: ["root"], bytes: 10)
        policy.putListing("active", items: ["a"], bytes: 100)
        policy.setOwner("pane", .init(listings: ["active"]))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init())
        #expect(policy.accounting.ordinaryBytes == 0 && policy.accounting.protectedBytes == 120)
        #expect(policy.accounting.protectedFiles == 2 && policy.accounting.protectedListings == 1)
        policy.setOwner("pane", .init(items: ["a"]))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(listings: ["active"]))
        #expect(policy.accounting.protectedBytes == 20)
        policy.setOwner("pane", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["root", "a"])
    }

    @Test func ownersRegisteredBeforeMetadataProtectLaterRecords() {
        var policy = Policy()
        policy.setOwner("edit", .init(items: ["future"]))
        #expect(policy.accounting.ownerReferences == 1 && policy.accounting.protectedFiles == 0)
        policy.putFile("future", bytes: 10)
        policy.putFile("ordinary", bytes: 10)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["ordinary"])
        policy.putFile("future", parents: ["parent"], bytes: 20)
        policy.putFile("parent", bytes: 30)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init())
        #expect(policy.accounting.protectedBytes == 50)
        policy.setOwner("edit", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files == ["future", "parent"])
    }

    @Test func retainedSnapshotsKeepAncestorsAndEmptyFolderContext() {
        var policy = Policy()
        policy.putFile("root", aliases: [""], bytes: 10)
        policy.putFile("folder", parents: [""], bytes: 10)
        policy.putFile("child", parents: ["folder"], bytes: 10)
        policy.putFile("unused", bytes: 10)
        policy.putListing("folder", items: ["child"], context: ["folder"], bytes: 10)
        #expect(policy.prune(to: .init(files: 3, listings: 1, bytes: 40)) == .init(files: ["unused"]))
        #expect(policy.accounting.files == 3 && policy.accounting.listings == 1)
        policy.putListing("folder", items: [], context: ["folder"], bytes: 10)
        #expect(policy.prune(to: .init(files: 2, listings: 1, bytes: 30)) == .init(files: ["child"]))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(files: ["root", "folder"], listings: ["folder"]))
    }

    @Test func forgettingMetadataKeepsIndependentOwnersAndTheirSharedReferences() {
        var policy = Policy()
        policy.putFile("a", bytes: 10)
        policy.putListing("one", items: ["a"], bytes: 10)
        policy.setOwner("edit", .init(items: ["a"]))
        policy.setOwner("offline", .init(items: ["a"]))
        policy.forgetFile("a"); policy.forgetListing("one")
        #expect(policy.accounting.files == 0 && policy.accounting.listings == 0 && policy.accounting.bytes == 0)
        #expect(policy.accounting.owners == 2 && policy.accounting.ownerReferences == 2)
        policy.putFile("a", bytes: 20)
        policy.setOwner("edit", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init())
        policy.setOwner("offline", nil)
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(files: ["a"]))
    }

    @Test func canonicalIDsTakePrecedenceOverAliasesAndRepeatedPruningIsStable() {
        var policy = Policy()
        policy.putFile("old-root", aliases: ["root"], bytes: 10)
        policy.putFile("root", bytes: 20)
        policy.setOwner("pane", .init(items: ["root"]))
        let limits = Policy.Limits(files: 0, listings: 0, bytes: 0)
        #expect(policy.prune(to: limits) == .init(files: ["old-root"]))
        #expect(policy.accounting.protectedFiles == 1 && policy.accounting.protectedBytes == 20)
        #expect(policy.prune(to: limits) == .init())
    }

    @Test func conflictingAliasesProtectEveryOwnedSubtreeWithoutTrapping() {
        for order in [["left", "right"], ["right", "left"]] {
            var policy = Policy()
            for id in order { policy.putFile(id, aliases: ["ambiguous"], bytes: 10) }
            policy.putFile("left-child", parents: ["left"], bytes: 10)
            policy.putFile("right-child", parents: ["right"], bytes: 10)
            policy.putFile("ambiguous-child", parents: ["ambiguous"], bytes: 10)
            policy.putFile("ordinary", bytes: 10)
            policy.setOwner("offline", .init(subtrees: ["ambiguous"]))
            #expect(policy.accounting.aliasConflicts == 1)
            #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(files: ["ordinary"]))
            #expect(policy.accounting.protectedFiles == 5)
            policy.setOwner("offline", nil)
            #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)).files.count == 5)
            #expect(policy.accounting.aliasConflicts == 0)
        }
    }

    @Test func anOwnedSubtreeKeepsCompleteOfflineListingsUntilReleased() {
        var policy = Policy()
        policy.putFile("folder", aliases: ["/pinned"], bytes: 10)
        policy.putFile("child", parents: ["/pinned"], bytes: 10)
        policy.putListing("/pinned", items: ["child"], context: ["/pinned"], bytes: 20)
        policy.setOwner("offline", .init(subtrees: ["folder"]))
        let limits = Policy.Limits(files: 0, listings: 0, bytes: 0)
        #expect(policy.prune(to: limits) == .init())
        #expect(policy.accounting.protectedFiles == 2 && policy.accounting.protectedListings == 1)
        policy.setOwner("offline", nil)
        #expect(policy.prune(to: limits) == .init(files: ["folder", "child"], listings: ["/pinned"]))
    }

    @Test func shortcutDependenciesKeepTheirContextWithoutPinningTheirChildren() {
        var policy = Policy()
        policy.putFile("root", bytes: 10)
        policy.putFile("outside", parents: ["root"], bytes: 10)
        policy.putFile("target", parents: ["outside"], bytes: 10)
        policy.putFile("folder", parents: ["root"], bytes: 10)
        policy.putFile("shortcut", parents: ["folder"], dependencies: ["target"], bytes: 10)
        policy.putFile("target-child", parents: ["target"], bytes: 10)
        policy.setOwner("offline", .init(subtrees: ["folder"]))
        #expect(policy.prune(to: .init(files: 0, listings: 0, bytes: 0)) == .init(files: ["target-child"]))
        #expect(policy.accounting.protectedFiles == 5)
        policy.setOwner("offline", nil)
        policy.putListing("folder", items: ["shortcut"], context: ["folder"], bytes: 10)
        policy.putFile("ordinary", bytes: 10)
        #expect(policy.prune(to: .init(files: 5, listings: 1, bytes: 100)) == .init(files: ["ordinary"]))
    }

    private final class Item {
        let payload = String(repeating: "x", count: 256)
        let live: Locked<Int>
        init(_ live: Locked<Int>) { self.live = live; live.change { $0 += 1 } }
        deinit { live.change { $0 -= 1 } }
    }

    /// Apply the planner's decisions to real retained objects and complete snapshots. This exercises settled
    /// ownership, including duplicates in snapshots, rather than counting bookkeeping entries alone.
    @Test func repeatedBrowsingReleasesObjectsAndBoundsAllOrdinaryStorage() {
        var policy = Policy(), files: [String: Item] = [:], listings: [String: [Item]] = [:]
        let live = Locked(0), limits = Policy.Limits(files: 200, listings: 5, bytes: 200_000)
        for page in 0..<250 {
            var snapshot: [Item] = [], ids: Set<String> = []
            for offset in 0..<200 {
                let id = "\(page)-\(offset)", item = Item(live)
                files[id] = item; snapshot.append(item); ids.insert(id)
                policy.putFile(id, bytes: 300)
            }
            let key = "folder-\(page)"
            listings[key] = snapshot
            policy.putListing(key, items: ids, bytes: snapshot.count * 300)
            let removed = policy.prune(to: limits)
            for key in removed.listings { listings[key] = nil }
            for id in removed.files { files[id] = nil }
            #expect(policy.accounting.ordinaryFiles <= limits.files)
            #expect(policy.accounting.ordinaryListings <= limits.listings)
            #expect(policy.accounting.ordinaryBytes <= limits.bytes)
            #expect(files.count <= limits.files)
            // The current loop's snapshot can still own this page even if the policy rejected it.
            #expect(live.value <= limits.files + snapshot.count)
        }
        #expect(live.value <= limits.files)
        for snapshot in listings.values { #expect(snapshot.count == 200) }
        #expect(policy.accounting.files == files.count && policy.accounting.listings == listings.count)
    }
}
