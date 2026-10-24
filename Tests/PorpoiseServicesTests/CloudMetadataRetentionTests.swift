import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudMetadataRetentionTests {
    private final class Item: CloudMetadataItem, @unchecked Sendable {
        let id: String
        init(_ id: String) { self.id = id }
    }

    @Test func removedItemsAreReleasedWithoutRebuildingTheirDerivedIndex() throws {
        let scratch = try Scratch(), cache = CloudMetadataCache<Item>(directory: scratch.url)
        weak var removed: Item?
        do {
            let item = Item("removed")
            removed = item
            cache.remember([item])
            _ = cache.derived("by-id") { $0 }
        }
        cache.flush()
        #expect(removed != nil)
        _ = cache.apply([], removed: ["removed"], belongs: { _, _ in false })
        cache.flush()
        #expect(cache.file("removed") == nil)
        #expect(removed == nil)
    }

    @Test func clearReleasesDerivedItemsAndUnchangedReadsReuseTheIndex() throws {
        let scratch = try Scratch(), cache = CloudMetadataCache<Item>(directory: scratch.url)
        weak var removed: Item?
        do {
            let item = Item("removed")
            removed = item
            cache.remember([item])
            var builds = 0
            for _ in 0..<2 {
                _ = cache.derived("by-id") { files in
                    builds += 1
                    return files
                }
            }
            #expect(builds == 1)
        }
        cache.flush()
        cache.clear()
        #expect(cache.files.isEmpty)
        #expect(removed == nil)
    }
}
