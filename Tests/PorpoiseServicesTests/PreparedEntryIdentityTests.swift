import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct PreparedEntryIdentityTests {
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
