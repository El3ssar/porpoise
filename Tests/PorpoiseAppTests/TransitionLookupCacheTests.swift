import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.isolatedSettings) struct TransitionLookupCacheTests {
    init() { _ = NSApplication.shared }

    @Test func geometryChangesReuseTheIdentityLookupAndContentChangesReplaceIt() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let items = (0..<127).map { FileItem(url: scratch.path("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false) }
        model.searchResults = items
        model.props.mode = .details
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        scroll.documentView = view
        view.computeLayout()
        let revision = model.rowsRevision
        let key = view.key(ofRow: 100)
        let url = model.rows[100].item.url
        #expect(view.row(forKey: key) == 100)
        #expect(view.rowKeyBuildCount == 1)
        for width: CGFloat in [800, 1200, 900] {
            scroll.frame.size.width = width
            view.computeLayout()
            view.previewZoom(32, commitAfter: nil)
            #expect(view.row(forKey: key) == 100)
            #expect(view.row(forKey: "not-an-entry") == nil)
        }
        for mode in [ViewMode.icons, .compact, .columns, .details] {
            model.props.mode = mode
            view.computeLayout()
            #expect(view.row(forKey: key) == 100)
        }
        #expect(model.rowsRevision == revision)
        #expect(view.rowKeyBuildCount == 1)

        // Same row count, new order: cardinality cannot be used as a validity token.
        model.props.sortOrder = .descending
        view.computeLayout()
        let index = try #require(model.index(of: url))
        #expect(index != 100)
        #expect(view.row(forKey: key) == index)
        #expect(view.rowKeyBuildCount == 2)

        model.searchResults = [FileItem(url: scratch.path("replacement.txt"), name: "replacement.txt", isDirectory: false)]
        view.computeLayout()
        #expect(view.row(forKey: key) == nil)
        #expect(view.row(forKey: view.key(ofRow: 0)) == 0)
        #expect(view.rowKeyBuildCount == 3)
        #expect(scroll.documentView === view && view.window == nil)
    }

    @Test func duplicateIdentitiesKeepTheFirstRowWithoutRebuildingEveryLookup() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let item = FileItem(url: scratch.path("same.txt"), name: "same.txt", isDirectory: false)
        model.searchResults = [item, item]
        let view = ItemListView(model: model)
        view.computeLayout()
        #expect(model.rows.count == 2)
        let key = view.key(ofRow: 0)
        for _ in 0..<10 { #expect(view.row(forKey: key) == 0) }
        #expect(view.rowKeys.count == 1 && view.rowKeyBuildCount == 1)
        view.computeLayout()
        #expect(view.row(forKey: key) == 0)
        #expect(view.rowKeyBuildCount == 1)
        model.searchResults = []
        view.computeLayout()
        #expect(view.row(forKey: key) == nil)
    }
}
