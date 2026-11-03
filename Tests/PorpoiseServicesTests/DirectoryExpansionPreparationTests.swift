import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct DirectoryExpansionPreparationTests {
    @Test(arguments: [ItemRole.name, .size, .tags])
    func treeChangesReuseTopOrderAndStillSortNewChildren(role: ItemRole) async throws {
        let scratch = try Scratch("expansion-order")
        let folder = try scratch.folder("folder")
        let child10 = try scratch.file("folder/child10.txt", "abcdefghij")
        let child2 = try scratch.file("folder/child2.txt", "ab")
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        model.prepareRows = { input, done in pending.append((input, done)); return LocationLoad() }
        model.props.mode = .details
        model.props.sortRole = role
        let files = (0..<2000).reversed().map {
            FileItem(url: scratch.path("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false, size: Int64($0 % 7))
        }
        model.applyEdit(ListingEdit(folder: scratch.url, added: [try #require(FileItem.load(folder))] + files))
        let initial = try #require(pending.last)
        let first = try #require(initial.0.build())
        initial.1(first)
        pending = []
        model.setExpanded(folder, true)
        try #require(await eventually { pending.last?.0.children[folder]?.count == 2 })
        // Both the disclosure change and the later child listing preserve the realized top-level order.
        #expect(!pending.isEmpty && pending.allSatisfy { $0.0.ordered?.map(\.url) == first.top.map(\.url) })
        let expanded = try #require(pending.last)
        expanded.1(try #require(expanded.0.build()))
        #expect(model.rows.filter { $0.depth == 0 }.map(\.item.url) == first.top.map(\.url))
        #expect(model.rows.filter { $0.depth == 1 }.map(\.item.url) == [child2, child10])
        model.selection = [child2]
        model.currentURL = child2
        model.setExpanded(folder, false)
        let collapsed = try #require(pending.last)
        #expect(collapsed.0.ordered?.map(\.url) == first.top.map(\.url))
        collapsed.1(try #require(collapsed.0.build()))
        #expect(model.rows.map(\.item.url) == first.top.map(\.url))
        #expect(model.selection.isEmpty && model.currentURL == folder)
        model.setExpanded(folder, true)
        model.collapseAll()
        let allCollapsed = try #require(pending.last)
        #expect(allCollapsed.0.ordered?.map(\.url) == first.top.map(\.url))
        allCollapsed.1(try #require(allCollapsed.0.build()))
        #expect(model.rows.count == 2001 && model.rows.allSatisfy { !$0.isExpanded })
    }

    @Test func expansionDuringANewerListingCannotReuseThePreviousTopOrder() throws {
        let scratch = try Scratch("expansion-new-listing")
        let folder = try scratch.folder("folder")
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.props.mode = .details
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        model.prepareRows = { input, done in pending.append((input, done)); return LocationLoad() }
        let files = (0..<2000).map {
            FileItem(url: scratch.path("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        model.applyEdit(ListingEdit(folder: scratch.url, added: [try #require(FileItem.load(folder))] + files))
        let initial = try #require(pending.last)
        initial.1(try #require(initial.0.build()))
        let replacement = FileItem(url: files[0].url, name: "renamed.txt", isDirectory: false)
        model.applyEdit(ListingEdit(folder: scratch.url, replaced: [replacement]))
        model.setExpanded(folder, true)
        let current = try #require(pending.last)
        #expect(current.0.ordered == nil)
        current.1(try #require(current.0.build()))
        #expect(model.rows.contains { $0.item == replacement })
        #expect(!model.rows.contains { $0.item == files[0] })
    }
}
