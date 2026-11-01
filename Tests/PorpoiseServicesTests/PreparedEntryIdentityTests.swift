import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct PreparedEntryIdentityTests {
    @Test func rowPreparationReusesListingIdentitiesAndResolvesOnlyNewEntries() throws {
        let scratch = try Scratch()
        let original = try scratch.folder("original"), replacement = try scratch.folder("replacement")
        let alias = try scratch.symlink("alias", to: "original")
        let listed = FileItem(url: alias.appendingPathComponent("listed.txt"), name: "listed.txt", isDirectory: false)
        let originalKey = FilePath.key(listed.url)
        // The listing snapshot owns this identity even if the path changes before row preparation.
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let added = FileItem(url: alias.appendingPathComponent("new.txt"), name: "new.txt", isDirectory: false)
        var input = DirectoryModelPreparation(
            items: [listed, added], incoming: [], children: [:], expanded: [], props: ViewProperties(), filter: NameFilter(),
            choice: .natural, hideBackups: false, sizes: [:], knownTags: [:], ordered: nil)
        input.knownEntryKeys = [listed.url: originalKey]
        let result = try #require(input.build())
        #expect(result.keyCache[listed.url] == originalKey)
        #expect(result.keyCache[listed.url] == FilePath.key(original.appendingPathComponent("listed.txt")))
        #expect(result.keyCache[listed.url] != FilePath.key(listed.url))
        #expect(result.keyCache[added.url] == FilePath.key(replacement.appendingPathComponent("new.txt")))
        for (row, key) in zip(result.rows, result.keys) { #expect(key == result.keyCache[row.item.url]) }
        #expect(input.build(cancelled: { true }) == nil)
    }

    @Test func smallLocalListingRetainsWorkerResolvedIdentityAfterParentDisappears() async throws {
        let scratch = try Scratch()
        let real = try scratch.folder("real")
        try scratch.file("real/file.txt")
        let alias = try scratch.symlink("alias", to: "real")
        let model = try await DirectoryModel.loaded(alias)
        let expected = FilePath.key(real.appendingPathComponent("file.txt"))
        try FileManager.default.removeItem(at: alias)
        // No suspension: a watcher cannot replace the authoritative rows before this render lookup.
        #expect(model.identity(ofRow: 0) == expected)
    }

    @Test func borrowedListingKeepsPreparedIdentitiesWithDifferentOrdering() async throws {
        let scratch = try Scratch()
        let real = try scratch.folder("real")
        try scratch.file("real/file.txt")
        let alias = try scratch.symlink("alias", to: "real")
        let lender = try await DirectoryModel.loaded(alias)
        let borrower = DirectoryModel(location: alias)
        borrower.props.sortOrder = .descending
        #expect(borrower.takeListing(of: lender))
        let expected = FilePath.key(real.appendingPathComponent("file.txt"))
        try FileManager.default.removeItem(at: alias)
        #expect(borrower.identity(ofRow: 0) == expected)
    }

    @Test func searchSnapshotResolvesItsParentsBeforePublishing() async throws {
        let scratch = try Scratch()
        let real = try scratch.folder("real")
        try scratch.file("real/file.txt")
        let alias = try scratch.symlink("alias", to: "real")
        let file = alias.appendingPathComponent("file.txt")
        let item = try #require(FileItem.load(file))
        let model = DirectoryModel(location: scratch.url)
        let expected = FilePath.key(real.appendingPathComponent("file.txt"))
        var finished = false
        model.sortSearchResults([item]) { apply in
            try? FileManager.default.removeItem(at: alias)
            apply()
            finished = true
        }
        try #require(await eventually { finished })
        #expect(!FileManager.default.fileExists(atPath: alias.path))
        #expect(model.rows.count == 1 && model.identity(ofRow: 0) == expected)
    }
}
