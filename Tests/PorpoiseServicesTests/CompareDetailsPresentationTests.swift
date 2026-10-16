import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings, .serialized)
struct CompareDetailsPresentationTests {
    @Test func projectionsKeepGhostSlotsAndUseEachSidesSpelling() {
        let root = URL(fileURLWithPath: "/Projects")
        let left = SyncSnapshot(entries: [.init(path: "tree", kind: .directory), .init(path: "tree/a.txt", size: 15), .init(path: "left.txt")])
        let right = SyncSnapshot(
            entries: [.init(path: "Tree", kind: .directory), .init(path: "Tree/a.txt", size: 20), .init(path: "right.txt")], caseSensitive: false)
        let rows = CompareOutline(SyncComparator.compare(left, right)).visible(filter: .all, expanded: ["tree"])
        let l = CompareDetailsPresentation(rows, root: root, side: .left, expanded: ["tree"])
        let r = CompareDetailsPresentation(rows, root: root, side: .right, expanded: ["tree"])
        #expect(l.rows.map(\.item.name) == ["tree", "a.txt", "left.txt"])
        #expect(r.rows.map(\.item.name) == ["Tree", "a.txt", "right.txt"])
        #expect(l.counts.folders == 1); #expect(l.counts.files == 1)
        #expect(l.slots == [0, 1, 2]); #expect(r.slots == [0, 1, 3])
        #expect(l.rows[0].isExpanded); #expect(l.rows[1].depth == 1)
        #expect(l.rows[1].item.contentType == "public.plain-text")
        #expect(r.rows[1].item.url.path == "/Projects/Tree/a.txt")
        #expect(r.pathAliases["Tree"] == "tree"); #expect(r.pathAliases["Tree/a.txt"] == "tree/a.txt")
        #expect(l.pathAliases.isEmpty)
    }
    @Test func realRowsRemainAuthoritativeAcrossBrowseReloadAndResume() async throws {
        let scratch = try Scratch(); try scratch.file("before.txt")
        let model = DirectoryModel(location: scratch.url); model.reload()
        #expect(await eventually(5) { !model.isLoading && model.rows.count == 1 })
        model.defersPresentation = true
        let rows = CompareOutline(
            SyncComparator.compare(
                .init(entries: [.init(path: "nested", kind: .directory), .init(path: "nested/file.txt", size: 8)]), .init(entries: []))
        )
        .visible(filter: .all, expanded: ["nested"])
        // Expanded nested entries also flow through ordinary selectedItems, menus and Quick Look.
        let projection = CompareDetailsPresentation(rows, root: scratch.url, side: .left, expanded: ["nested"])
        model.presentComparisonRows(projection.rows, counts: projection.counts)
        let item = try #require(projection.rows.last?.item)
        #expect(item.url.path.hasSuffix("nested/file.txt"))
        model.selection = [item.url]; #expect(model.selectedItems == [item])
        #expect(model.visibleCounts.folders == projection.counts.folders)
        #expect(model.visibleCounts.files == projection.counts.files)
        #expect(model.visibleCounts.bytes == projection.counts.bytes)
        try scratch.file("after.txt"); model.reload()
        #expect(await eventually(5) { !model.isLoading && model.items.count == 2 })
        #expect(model.rows.map(\.item.url) == projection.rows.map(\.item.url))
        var expanded: URL?
        model.onComparisonExpansion = { url, _ in expanded = url }
        model.setExpanded(scratch.url, true); #expect(expanded == scratch.url)
        model.onComparisonExpansion = nil
        model.defersPresentation = false
        #expect(Set(model.rows.map(\.item.name)) == ["before.txt", "after.txt"])
        // A projection cannot overwrite ordinary browsing once Compare is gone.
        model.presentComparisonRows([]); #expect(model.rows.count == 2)
    }
}

extension CompareDetailsPresentationTests {
    @Test func missingCounterpartStaysIncompleteAndCanReappearLive() throws {
        let scratch = try Scratch(), root = scratch.url.appendingPathComponent("missing")
        let missing = try CompareBrowserScan.scan(root, options: .init(), cancellation: DiskCancellation())
        #expect(missing.entries.isEmpty); #expect(!missing.complete)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("now here".utf8).write(to: root.appendingPathComponent("new.txt"))
        let present = try CompareBrowserScan.scan(root, options: .init(), cancellation: DiskCancellation())
        #expect(present.complete); #expect(present.entries.map(\.path) == ["new.txt"])
        let token = DiskCancellation(); token.cancel()
        #expect(throws: (any Error).self) { try CompareBrowserScan.scan(root, options: .init(), cancellation: token) }
        let absentToken = DiskCancellation(); absentToken.cancel()
        #expect(throws: (any Error).self) {
            try CompareBrowserScan.scan(root.appendingPathComponent("absent"), options: .init(), cancellation: absentToken)
        }
        #expect(throws: (any Error).self) {
            try CompareBrowserScan.scan(URL(string: "unsupported://host/path")!, options: .init(), cancellation: DiskCancellation())
        }
    }
}
