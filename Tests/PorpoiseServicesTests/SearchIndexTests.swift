import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

@MainActor struct SearchIndexTests {
    private func setup(_ scratch: Scratch, content: Bool = false) -> SearchIndex {
        let defaults = UserDefaults(suiteName: "PorpoiseIndexTests.\(UUID())")!
        let service = SearchIndex(directory: scratch.path("store"), defaults: defaults)
        var config = IndexConfiguration()
        config.enabled = true; config.roots = [scratch.path("root").path]; config.content = content
        config.exclusions = [scratch.path("root/private").path]
        service.configure(config)
        return service
    }
    private func waitReady(_ index: SearchIndex) async throws {
        try #require(await eventually(10) { !index.status.building && index.status.updated != nil })
    }
    @Test func crawlerSkipsSymlinksAndExcludedTrees() throws {
        let s = try Scratch()
        try s.file("root/visible.txt")
        try s.file("root/private/secret.txt")
        try s.symlink("root/link", to: s.path("root").path)
        let table = IndexCrawler.crawl(s.path("root").path, exclusions: [s.path("root/private").path])
        #expect(try table.search(IndexQuery("secret")).isEmpty)
        #expect(try table.search(IndexQuery("visible")).count == 1)
        #expect(table.count == 3)
    }
    @Test func coverageExclusionsAndContentVerification() async throws {
        let s = try Scratch()
        try s.file("root/report.txt", "a very unusual phrase")
        try s.file("root/private/secret.txt", "unusual")
        try s.file("root/node_modules/ignored.txt")
        try s.file("root/.git/objects/ignored.txt")
        let index = setup(s, content: true)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        let root = s.path("root")
        #expect(index.search("report ext:txt", scope: root)?.paths == [IndexPath.canonical(s.path("root/report.txt").path)])
        #expect(index.search("unusual", scope: root, contents: true)?.snippets[IndexPath.canonical(s.path("root/report.txt").path)] == "a very unusual phrase")
        #expect(index.search("ignored", scope: root)?.paths.isEmpty == true)
        #expect(index.search("secret", scope: s.path("root/private")) == nil)
        #expect(index.search("report", scope: s.url) == nil)
        #expect(index.search("report", scope: root, cancelled: { true })?.paths.isEmpty == true)
        index.configure(IndexConfiguration())
        #expect(index.search("report", scope: root) == nil)
    }
    @Test func realFSEventsCreationRenameRemovalAndRestart() async throws {
        let s = try Scratch()
        try s.folder("root")
        let index = setup(s)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        let started = Date()
        try s.file("root/new-needle.txt", "hello")
        try #require(await eventually(5) { index.search("needle", scope: s.path("root"))?.paths.count == 1 })
        print("Index live-create latency: \(Date().timeIntervalSince(started)) seconds")
        try FileManager.default.moveItem(at: s.path("root/new-needle.txt"), to: s.path("root/renamed.txt"))
        try #require(await eventually(5) { index.search("needle", scope: s.path("root"))?.paths.isEmpty == true && index.search("renamed", scope: s.path("root"))?.paths.count == 1 })
        try FileManager.default.removeItem(at: s.path("root/renamed.txt"))
        try #require(await eventually(5) { index.search("renamed", scope: s.path("root"))?.paths.isEmpty == true })
        // A new service loads the on-disk snapshot, including tombstones.
        try #require(await eventually(5) { FileManager.default.fileExists(atPath: s.path("store/manifest.json").path) })
        let restored = SearchIndex(directory: s.path("store"), defaults: UserDefaults(suiteName: "PorpoiseIndexTests.\(UUID())")!)
        restored.configure(index.configuration)
        defer { restored.configure(IndexConfiguration()) }
        try await waitReady(restored)
        #expect(restored.search("renamed", scope: s.path("root"))?.paths.isEmpty == true)
    }
    @Test func fallbackRunnerStillFindsFilesWithIndexOff() async throws {
        let s = try Scratch(); try s.file("fallback-name.txt")
        var result: [FileItem]?
        let runner = SearchRunner(text: "fallback", scope: s.url, contents: false) { items, done in if done { result = items } }
        runner.usesSpotlight = false; runner.folderTools = nil
        runner.index = SearchIndex(directory: s.path("index"), defaults: UserDefaults(suiteName: "PorpoiseIndexTests.\(UUID())")!)
        runner.start(); defer { runner.stop() }
        try #require(await eventually(5) { result != nil })
        #expect(result?.map(\.name) == ["fallback-name.txt"])
    }
}
