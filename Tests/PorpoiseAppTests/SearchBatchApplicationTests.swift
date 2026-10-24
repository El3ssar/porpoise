import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct SearchBatchApplicationTests {
    init() { _ = NSApplication.shared }

    @Test func growingContentBatchesKeepSelectionGroupingAndTheFoldersStoredStyle() async throws {
        let scratch = try Scratch("search-batches")
        var folderStyle = ViewProperties()
        folderStyle.mode = .compact
        folderStyle.sortRole = .name
        folderStyle.sortOrder = .ascending
        ViewStyleStore().common = folderStyle
        let storedStyle = try #require(Settings.store.data(forKey: "viewProps"))
        let pane = ViewContainer(url: scratch.url)
        pane.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        defer { pane.closeSearch() }
        try #require(await eventually { !pane.model.isLoading })
        #expect(pane.model.props.mode == .compact)

        var runner: SearchRunner?
        pane.configureSearchForTesting = {
            $0.usesIndex = false
            $0.usesSpotlight = false
            $0.folderTools = nil
            runner = $0
        }
        pane.showSearch()
        pane.searchBar(pane.searchBar, search: "needle", everywhere: false, contents: true)
        // Let the real empty-folder search finish before delivering its later batches through the same callback.
        try #require(await eventually { pane.model.isSearching && pane.statusBar.progress == nil })
        let search = try #require(runner)
        let named = FileItem(url: scratch.path("needle-z.txt"), name: "needle-z.txt", isDirectory: false)
        let content = FileItem(url: scratch.path("body.txt"), name: "body.txt", isDirectory: false)
        search.update([named, content], false)
        try #require(await eventually { pane.model.rows.map(\.item.name) == ["needle-z.txt", "body.txt"] })
        #expect(pane.model.groups.map(\.title) == ["Name matches", "Content matches"])
        #expect(pane.model.props.mode == .details && pane.model.props.roles(for: .details).contains(.path))
        #expect(pane.model.searchMatches?.text == "needle" && pane.model.searchMatches?.contents == true)
        pane.model.selection = [named.url]
        pane.model.currentURL = named.url

        let added = FileItem(url: scratch.path("needle-a.txt"), name: "needle-a.txt", isDirectory: false)
        search.update([named, content, added], true)
        try #require(await eventually { pane.model.rows.map(\.item.name) == ["needle-a.txt", "needle-z.txt", "body.txt"] })
        #expect(pane.model.selection == [named.url] && pane.model.currentURL == named.url)
        #expect(pane.model.groups.map(\.title) == ["Name matches", "Content matches"])
        #expect(pane.statusBar.progress == nil)
        #expect(Settings.store.data(forKey: "viewProps") == storedStyle)

        pane.closeSearch()
        #expect(!pane.model.isSearching && pane.model.searchMatches == nil)
        #expect(pane.model.props == folderStyle)
        #expect(Settings.store.data(forKey: "viewProps") == storedStyle)
    }
}
