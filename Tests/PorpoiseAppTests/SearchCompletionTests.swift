import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct SearchCompletionTests {
    init() { _ = NSApplication.shared }

    @Test func completedFolderSearchDoesNotRestoreProgressAfterItsDelayedBatch() async throws {
        let scratch = try Scratch("completed-search")
        try scratch.file("needle-target.txt")
        let fd = TestPaths.repo.appendingPathComponent("build/search-tools/fd").path
        try #require(FileManager.default.isExecutableFile(atPath: fd))
        let pane = ViewContainer(url: scratch.url)
        pane.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        try #require(await eventually { !pane.model.isLoading })
        pane.configureSearchForTesting = { runner in
            runner.usesIndex = false
            runner.folderTools = .init(fd: fd)
        }
        defer { pane.closeSearch() }
        pane.showSearch()
        pane.searchBar(pane.searchBar, search: "needle-target", everywhere: false, contents: false)
        #expect(pane.statusBar.progress != nil)
        try #require(
            await eventually {
                pane.model.isSearching && pane.model.rows.map(\.item.name) == ["needle-target.txt"] && pane.statusBar.progress == nil
            })
        // Exercise the real ViewContainer callback after the service reports completion.
        try await Task.sleep(for: .milliseconds(500))
        #expect(pane.statusBar.progress == nil)
        #expect(pane.model.rows.map(\.item.name) == ["needle-target.txt"])
    }
}
