import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct DirectoryPreparedLookupTests {
    @Test func preparedIndexesKeepTheFirstDuplicateAndAuthoritativeAliasIdentity() throws {
        let scratch = try Scratch("prepared-lookup")
        let physical = try scratch.folder("physical")
        let alias = try scratch.symlink("alias", to: "physical")
        let first = FileItem(url: alias.appendingPathComponent("file.txt"), name: "first", isDirectory: false)
        let duplicate = FileItem(url: first.url, name: "duplicate", isDirectory: false)
        let sameEntry = FileItem(url: physical.appendingPathComponent("file.txt"), name: "physical", isDirectory: false)
        let originalIdentity = FilePath.key(first.url)
        let input = DirectoryModelPreparation(
            items: [first, duplicate, sameEntry], incoming: [], children: [:], expanded: [], props: ViewProperties(),
            filter: NameFilter(), choice: .natural, hideBackups: false, sizes: [:], knownTags: [:],
            ordered: [first, duplicate, sameEntry], knownEntryKeys: [first.url: originalIdentity, sameEntry.url: originalIdentity])
        // A changed symlink must not cause the lookup index to re-resolve identities already supplied by the listing.
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: try scratch.folder("replacement"))
        let result = try #require(input.build())
        #expect(result.rowIndex[first.url] == 0)
        #expect(result.rowIndex[sameEntry.url] == 2)
        #expect(result.rowIndexByPath[originalIdentity] == 0)
        #expect(result.rowIndexByPath[FilePath.key(first.url)] == nil)
        #expect(result.rowIndex == Dictionary(result.rows.enumerated().map { ($1.item.url, $0) }, uniquingKeysWith: { first, _ in first }))
        #expect(result.rowIndexByPath == Dictionary(zip(result.keys, result.rows.indices), uniquingKeysWith: { first, _ in first }))
        #expect(input.build(cancelled: { true }) == nil)
    }

    @Test func publicationProvidesCurrentLookupsBeforeNotifyingAndRejectsOlderIndexes() throws {
        let scratch = try Scratch("lookup-publication")
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        model.prepareRows = { input, done in pending.append((input, done)); return LocationLoad() }
        let items = (0..<2001).map {
            FileItem(url: scratch.path("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        model.applyEdit(ListingEdit(folder: scratch.url, added: items))
        let obsolete = try #require(pending.last)
        model.props.sortOrder = .descending
        let current = try #require(pending.last)
        let prepared = try #require(current.0.build())
        var notifications = 0
        model.onChange = {
            notifications += 1
            for (url, index) in prepared.rowIndex { #expect(model.index(of: url) == index) }
            for (key, index) in prepared.rowIndexByPath {
                #expect(model.index(of: URL(fileURLWithPath: key)) == index)
            }
        }
        current.1(prepared)
        #expect(!model.isLoading && notifications == 1)
        obsolete.1(try #require(obsolete.0.build()))
        #expect(notifications == 1 && model.rows.first?.item.name == "file-2000.txt")
        let revision = model.rowsRevision
        model.props.mode = .compact
        #expect(model.rowsRevision == revision && notifications == 2)
        #expect(model.index(of: items[0].url) == 2000)
        model.onChange = nil
        model.filter = NameFilter(text: "file-2000.txt")
        let filtered = try #require(pending.last)
        filtered.1(try #require(filtered.0.build()))
        #expect(model.rows.count == 1 && model.index(of: items[2000].url) == 0)
        #expect(model.index(of: items[0].url) == nil)
    }
}
