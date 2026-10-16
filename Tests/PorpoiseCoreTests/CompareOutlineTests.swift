import Foundation
import Testing

@testable import PorpoiseCore

struct CompareOutlineTests {
    private func file(_ path: String, size: Int64 = 1) -> SyncEntry { .init(path: path, size: size, modified: Date(timeIntervalSince1970: 100)) }
    @Test func filtersKeepMatchingAncestorsAndAlignExpandedGhosts() {
        let directory = SyncEntry(path: "d", kind: .directory)
        let comparison = SyncComparator.compare(
            .init(entries: [directory, file("d/left"), file("same")]),
            .init(entries: [directory, file("d/right"), file("same")]))
        let outline = CompareOutline(comparison)
        #expect(outline.visible(filter: .differences, expanded: []).map(\.path) == ["d"])
        #expect(outline.visible(filter: .onlyLeft, expanded: ["d"]).map(\.path) == ["d", "d/left"])
        #expect(outline.visible(filter: .onlyRight, expanded: ["d"]).map(\.path) == ["d", "d/right"])
        #expect(outline.visible(filter: .same, expanded: []).map(\.path) == ["same"])
        #expect(outline.visible(filter: [], expanded: ["d"]).isEmpty)
        #expect(outline.counts[CompareFilter.onlyLeft.rawValue] == 1)
        #expect(outline.visible(filter: .all, expanded: ["d"]).count == 4)
    }
    @Test func linkedNavigationUsesComponentBoundariesAndSameRemoteEndpoint() {
        let root = URL(fileURLWithPath: "/Projects")
        #expect(LinkedBrowsing.relativePath(root, below: root) == "")
        #expect(LinkedBrowsing.relativePath(root.appendingPathComponent("Invoices/2026"), below: root) == "Invoices/2026")
        #expect(LinkedBrowsing.relativePath(URL(fileURLWithPath: "/Projects-old/a"), below: root) == nil)
        #expect(LinkedBrowsing.relativePath(URL(fileURLWithPath: "/Projects/../outside"), below: root) == nil)
        #expect(LinkedBrowsing.relativePath(URL(string: "sftp://a/root/d")!, below: URL(string: "sftp://a/root")!) == "d")
        #expect(LinkedBrowsing.relativePath(URL(string: "sftp://b/root/d")!, below: URL(string: "sftp://a/root")!) == nil)
    }
    @Test func matchingFolderNamesUseDistinctAncestorLabels() {
        let names = CompareOutline.sideNames(URL(fileURLWithPath: "/Home/Projects"), URL(fileURLWithPath: "/Backup/Projects"))
        #expect(names.0 == "Projects"); #expect(names.1 == "Backup")
        let remote = CompareOutline.sideNames(URL(fileURLWithPath: "/Home/Projects"), URL(string: "sftp://nas.local/Projects")!)
        #expect(remote.1 == "nas.local")
    }
    @Test func tenThousandRowFilteringUsesCachedTree() {
        let entries = (0..<10_000).map { file("file-\($0)") }
        let comparison = SyncComparator.compare(.init(entries: entries), .init(entries: []))
        let outline = CompareOutline(comparison), start = Date()
        let result = outline.visible(filter: .onlyLeft, expanded: [])
        print("COMPARE_FILTER 10000 cached rows: \(Date().timeIntervalSince(start) * 1000) ms")
        #expect(result.count == 10_000)
    }
}

extension CompareOutlineTests {
    @Test func numericNamesUseFinderOrderInBothDirectionsAndKeepFoldersFirst() {
        let folder = SyncEntry(path: "Folder10", kind: .directory)
        var outline = CompareOutline(
            SyncComparator.compare(
                .init(entries: [file("File10"), folder, file("File1"), file("File2"), file("Folder10/File10"), file("Folder10/File2")]),
                .init(entries: [])))
        #expect(
            outline.visible(filter: .all, expanded: ["Folder10"]).map(\.path)
                == ["Folder10", "Folder10/File2", "Folder10/File10", "File1", "File2", "File10"])
        outline.sort(by: .name, side: .left, ascending: false)
        #expect(
            outline.visible(filter: .all, expanded: ["Folder10"]).map(\.path)
                == ["Folder10", "Folder10/File10", "Folder10/File2", "File10", "File2", "File1"])
    }
    @Test func changedFilterDoesNotMatchFolderRollupOfOnlyItems() {
        let a = SyncEntry(path: "Brand", kind: .directory), b = SyncEntry(path: "Website", kind: .directory)
        let outline = CompareOutline(
            SyncComparator.compare(
                .init(entries: [a, b, file("Brand/only", size: 2), file("Website/index", size: 7)]),
                .init(entries: [a, b, file("Website/index", size: 3)])))
        #expect(outline.visible(filter: .changed, expanded: []).map(\.path) == ["Website"])
        #expect(outline.visible(filter: .onlyLeft, expanded: []).map(\.path) == ["Brand"])
        #expect(outline.totalBytes[.left] == 9)
        #expect(outline.totalBytes[.right] == 3)
    }
    @Test func caseOnlyParentSpellingKeepsOneSidedChildrenAndCountsAligned() {
        let outline = CompareOutline(
            SyncComparator.compare(
                .init(entries: [.init(path: "Tree", kind: .directory), file("Tree/same")]),
                .init(entries: [.init(path: "tree", kind: .directory), file("tree/same"), file("tree/right")], caseSensitive: false)))
        let rows = outline.visible(filter: .onlyRight, expanded: ["Tree"])
        #expect(rows.map(\.path) == ["Tree", "Tree/right"])
        #expect(rows.last?.right?.path == "tree/right")
        #expect(outline.childCounts[.left]?["Tree"] == 1)
        #expect(outline.childCounts[.right]?["Tree"] == 2)
    }
    @Test func folderCountsArePerSideAndCountImmediateChildren() {
        let folder = SyncEntry(path: "d", kind: .directory), nested = SyncEntry(path: "d/nested", kind: .directory)
        let outline = CompareOutline(
            SyncComparator.compare(
                .init(entries: [folder, nested, file("d/nested/deep"), file("d/left")]),
                .init(entries: [folder, file("d/right")])))
        #expect(outline.childCounts[.left]?["d"] == 2)
        #expect(outline.childCounts[.right]?["d"] == 1)
        #expect(outline.childCounts[.left]?["d/nested"] == 1)
        #expect(outline.childCounts[.right]?["d/nested"] == nil)
    }
    @Test func caseOnlyNamesRemainVisibleAndSiblingSortPreservesTree() {
        let comparison = SyncComparator.compare(
            .init(entries: [file("README", size: 8)]), .init(entries: [file("Readme", size: 8)], caseSensitive: false))
        let outline = CompareOutline(comparison)
        #expect(comparison.rows.first?.status == .same)
        #expect(outline.visible(filter: .changed, expanded: []).first?.status == .changed(.unknown))
        let dir = SyncEntry(path: "d", kind: .directory)
        var sorted = CompareOutline(
            SyncComparator.compare(.init(entries: [dir, file("d/a", size: 8), file("d/b", size: 1), file("z", size: 2)]), .init(entries: [])))
        sorted.sort(by: .size, side: .left, ascending: true)
        #expect(sorted.visible(filter: .all, expanded: ["d"]).map(\.path) == ["d", "d/b", "d/a", "z"])
    }
}
