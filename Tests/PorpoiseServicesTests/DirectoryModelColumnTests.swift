import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

/// Column view's needs of the model: every folder in the columns shows as Columns without that being saved as its
/// own mode, and a column's listing shows at once in another model of the same folder.
@MainActor @Suite(.serialized, .isolatedSettings) struct DirectoryModelColumnTests {
    @Test func browsingColumnsKeepsTheModeWithoutSavingIt() async throws {
        let s = try Scratch()
        try s.folder("photos")
        for i in 0..<6 { try s.file("photos/\(i).png") }
        Settings.store.set(true, forKey: "perFolder")
        Settings.store.set(true, forKey: "dynamicView")
        var own = ViewProperties()
        own.mode = .icons
        own.sortRole = .size
        ViewStyleStore().save(own, for: s.path("photos"))

        let m = try await DirectoryModel.loaded(s.url) { $0.browsesColumns = true }
        #expect(m.props.mode == .columns)
        m.setLocation(s.path("photos"))
        try #require(await eventually { !m.isLoading })
        // Its own sort applies; the media folder doesn't turn the view into Icons; the mode isn't saved.
        #expect(m.props.mode == .columns && m.props.sortRole == .size)
        m.props.sortOrder = .descending
        m.saveProps()
        let saved = ViewStyleStore().style(for: s.path("photos"))
        #expect(saved.mode == .icons && saved.sortOrder == .descending)

        // A search shows Details over Columns, and Columns comes back with the folder after it.
        m.showSearchView()
        #expect(m.props.mode == .details)
        m.endSearchView()
        #expect(m.props.mode == .columns)
        m.reloadProps()
        #expect(m.props.mode == .columns && m.props.sortOrder == .descending)

        // Leaving Column view gives the folder its own mode back.
        m.browsesColumns = false
        #expect(m.props.mode == .icons)
        // Choosing Columns in a folder is that folder's own choice: saved as such.
        m.props.mode = .columns
        m.saveProps()
        m.browsesColumns = true
        m.browsesColumns = false
        #expect(m.props.mode == .columns && ViewStyleStore().style(for: s.path("photos")).mode == .columns)
    }

    @Test func aColumnsListingShowsAtOnceInAnotherModel() async throws {
        let s = try Scratch()
        for name in ["b.txt", "a.txt", "c"] { if name == "c" { try s.folder(name) } else { try s.file(name) } }
        let lender = try await DirectoryModel.loaded(s.url)
        let m = DirectoryModel(location: s.url, prefetchFolders: false)
        var changes = 0
        m.onChange = { changes += 1 }
        m.reload()
        // Before its own listing arrives, the lender's rows show, as they are.
        m.showListing(of: lender)
        #expect(m.rowNames == ["c", "a.txt", "b.txt"] && changes >= 1)
        #expect(m.rows.map(\.item) == lender.rows.map(\.item))
        try #require(await eventually { !m.isLoading })
        #expect(m.rowNames == ["c", "a.txt", "b.txt"])

        // Nothing changes once it has rows of its own, for another folder, or while either searches.
        let before = m.rowsRevision
        m.showListing(of: lender)
        #expect(m.rowsRevision == before)
        let other = DirectoryModel(location: s.path("c"), prefetchFolders: false)
        other.showListing(of: lender)
        #expect(other.rows.isEmpty)
        let searching = DirectoryModel(location: s.url, prefetchFolders: false)
        searching.searchResults = []
        searching.showListing(of: lender)
        #expect(searching.items.isEmpty)
        other.showListing(of: other)
        #expect(other.items.isEmpty)
    }

    @Test func anotherSortSortsTheLentItems() async throws {
        let s = try Scratch()
        try s.file("a.txt", size: 30)
        try s.file("b.txt", size: 10)
        try s.file("c.txt", size: 20)
        Settings.store.set(true, forKey: "perFolder")
        let lender = try await DirectoryModel.loaded(s.url)
        var bySize = ViewProperties()
        bySize.sortRole = .size
        let m = DirectoryModel(location: s.url, prefetchFolders: false)
        m.props = bySize
        m.showListing(of: lender)
        #expect(m.rowNames == ["b.txt", "c.txt", "a.txt"])
    }

    @Test func aBigListingIsTakenWithoutSortingAgain() async throws {
        let s = try Scratch()
        for i in 0..<2500 { try s.file(String(format: "f%05d.txt", i)) }
        let lender = try await DirectoryModel.loaded(s.url)
        try #require(lender.rows.count == 2500)
        let m = DirectoryModel(location: s.url, prefetchFolders: false)
        m.reload()
        m.showListing(of: lender)
        // Rows of 2,000 items and more are otherwise prepared in the background: these show in this same turn.
        #expect(m.rows.count == 2500 && m.rows.first?.item.name == "f00000.txt")
        m.selection = [s.path("f00042.txt")]
        try #require(await eventually { !m.isLoading })
        #expect(m.rows.count == 2500 && m.selection == [s.path("f00042.txt")])
    }
}
