import Foundation
import Darwin
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

    @Test func runningSearchRefreshesWhenIndexedFileAppearsAndStopsCleanly() async throws {
        let s = try Scratch(); try s.folder("root")
        let index = setup(s)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        var updates: [[String]] = []
        let runner = SearchRunner(text: "visible", scope: s.path("root"), contents: false) { items, done in
            if done { updates.append(items.map(\.name)) }
        }
        runner.index = index; runner.start()
        defer { runner.stop() }
        try #require(await eventually(5) { !updates.isEmpty })
        try s.file("root/visible.txt")
        try #require(await eventually(5) { updates.last == ["visible.txt"] })
        runner.stop()
        let count = updates.count
        try s.file("root/visible2.txt")
        try #require(await eventually(5) { index.search("visible", scope: s.path("root"))?.paths.count == 2 })
        #expect(updates.count == count)
        #expect(index.status.count == 3) // Root and two files, with patches counted once.
    }


    @Test func packagesAndIndexStorageAreNotRecursivelyIndexed() async throws {
        let s = try Scratch()
        try s.file("root/Test.app/Contents/hidden-name.txt")
        try s.file("root/visible.txt")
        let index = SearchIndex(directory: s.path("root/index-store"), defaults: UserDefaults(suiteName: "PorpoiseIndexTests.\(UUID())")!)
        var config = IndexConfiguration(); config.enabled = true; config.roots = [s.path("root").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        #expect(index.search("hidden-name", scope: s.path("root"))?.paths.isEmpty == true)
        try #require(await eventually(5) { FileManager.default.fileExists(atPath: s.path("root/index-store/manifest.json").path) })
        try s.file("root/after.txt")
        try #require(await eventually(5) { index.search("after", scope: s.path("root"))?.paths.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(index.search("idx", scope: s.path("root"))?.paths.isEmpty == true)
        #expect(index.status.count == 4) // Root, package, visible and after.
    }
    @Test func permissionHolesUseFallbackUntilReadableAgain() async throws {
        let s = try Scratch(); try s.file("root/denied/hidden.txt"); try s.file("root/allowed/visible.txt")
        let path = s.path("root/denied").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        let index = setup(s)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        #expect(index.search("hidden", scope: s.path("root")) == nil)
        #expect(index.search("visible", scope: s.path("root/allowed"))?.paths.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try #require(await eventually(5) { index.search("hidden", scope: s.path("root"))?.paths.count == 1 })
    }
    @Test func offlineChangesReplayFromInitialSavedCursor() async throws {
        let s = try Scratch(); try s.file("root/original.txt")
        let index = setup(s)
        try await waitReady(index)
        try #require(await eventually(5) { FileManager.default.fileExists(atPath: s.path("store/manifest.json").path) })
        let configuration = index.configuration
        index.configure(IndexConfiguration())
        try s.file("root/offline-file.txt")
        let restored = SearchIndex(directory: s.path("store"), defaults: UserDefaults(suiteName: "PorpoiseIndexTests.\(UUID())")!)
        restored.configure(configuration)
        defer { restored.configure(IndexConfiguration()) }
        try await waitReady(restored)
        try #require(await eventually(5) { restored.search("offline-file", scope: s.path("root"))?.paths.count == 1 })
    }
    @Test func eventBurstsConvergeWithoutDuplicateResults() async throws {
        let s = try Scratch(); try s.folder("root")
        let index = setup(s)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        for n in 0..<128 { try s.file("root/burst-\(n).txt") }
        try #require(await eventually(5) { index.search("burst-", scope: s.path("root"))?.paths.count == 128 })
        #expect(index.status.count == 129)
    }


    @Test func boundedContentReadsRejectSpecialAndOversizedFiles() throws {
        let s = try Scratch()
        try s.file("text", "hello")
        try s.file("large", size: 65537)
        try s.file("binary", "hi\0there")
        try s.symlink("link", to: s.path("text").path)
        #expect(mkfifo(s.path("pipe").path, 0o600) == 0)
        #expect(IndexFileText.read(s.path("text").path, limit: 65536) == "hello")
        for name in ["large", "binary", "link", "pipe", "absent"] { #expect(IndexFileText.read(s.path(name).path, limit: 65536) == nil) }
    }


    @Test func symlinkEventsIndexTheLinkWithoutFollowingItsTarget() async throws {
        let s = try Scratch(); try s.folder("root"); try s.file("outside.txt", "outside content")
        let index = setup(s)
        defer { index.configure(IndexConfiguration()) }
        try await waitReady(index)
        try s.symlink("root/new-link", to: s.path("outside.txt").path)
        try #require(await eventually(5) { index.search("new-link", scope: s.path("root"))?.paths.count == 1 })
        #expect(index.search("outside.txt", scope: s.path("root"))?.paths.isEmpty == true)
        try FileManager.default.removeItem(at: s.path("root/new-link"))
        try #require(await eventually(5) { index.search("new-link", scope: s.path("root"))?.paths.isEmpty == true })
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
