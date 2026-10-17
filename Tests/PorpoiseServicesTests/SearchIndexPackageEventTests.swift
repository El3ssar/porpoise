import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A change inside a package is indexed as the package changing, never as its contents.
@MainActor struct SearchIndexPackageEventTests {
    @Test func aFileAddedInsideAPackageStaysHidden() async throws {
        let s = try Scratch()
        try s.file("root/Test.app/Contents/old.txt")
        let suite = "PorpoiseIndexTests.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: UserDefaults(suiteName: suite)!)
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try #require(await eventually(30) { !index.status.building && index.status.updated != nil })

        try s.file("root/Test.app/Contents/inner-new.txt")
        try s.file("root/outer-new.txt")
        try #require(await eventually(30) { index.search("outer-new", scope: s.path("root"))?.paths.count == 1 })
        // Both changes were reported together or the package's first: by now it has been handled.
        try #require(await eventually(30) { index.search("Test", scope: s.path("root"))?.paths.count == 1 })
        #expect(index.search("inner-new", scope: s.path("root"))?.paths.isEmpty == true)
        #expect(index.search("old", scope: s.path("root"))?.paths.isEmpty == true)
    }
}
