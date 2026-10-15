import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct SearchRefreshRegressionTests {
    @Test(arguments: [true, false]) func idleResultsDoNotRestartOnIndexNotifications(indexEnabled: Bool) async throws {
        let s = try Scratch()
        for n in 0..<80 { try s.file("root/no-\(n).txt") }
        let suite = "PorpoiseSearchRefresh.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: UserDefaults(suiteName: suite)!)
        var config = IndexConfiguration()
        config.enabled = indexEnabled; config.roots = [s.path("root").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        if indexEnabled { try #require(await eventually(30) { !index.status.building && index.status.updated != nil }) }
        var updates: [(Int, Bool)] = []
        let runner = SearchRunner(text: "no", scope: s.path("root"), contents: false) { items, done in
            updates.append((items.count, done))
        }
        runner.index = index
        runner.usesSpotlight = false
        runner.folderTools = nil
        runner.start()
        defer { runner.stop() }
        try #require(await eventually(30) { updates.last?.1 == true })
        try #require(updates.last?.0 == 80)
        let initial = updates.count
        for _ in 0..<4 {
            NotificationCenter.default.post(name: SearchIndex.changed, object: index)
            try await Task.sleep(for: .milliseconds(250))
        }
        print("REFRESH_REPRO initial=\(initial) after=\(updates.count) batches=\(updates.map { $0.0 })")
        #expect(updates.count == initial)
    }
    @Test func liveChangesNeverReplayTheInitialBatch() async throws {
        let s = try Scratch()
        for n in 0..<80 { try s.file("root/sub/no-\(n).txt") }
        try s.file("root/unrelated.txt")
        let suite = "PorpoiseSearchRefresh.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: UserDefaults(suiteName: suite)!)
        var config = IndexConfiguration()
        config.enabled = true; config.roots = [s.path("root").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try #require(await eventually(30) { !index.status.building && index.status.updated != nil })
        var batches: [(items: [FileItem], done: Bool)] = []
        let runner = SearchRunner(text: "no", scope: s.path("root/sub"), contents: false) { items, done in batches.append((items, done)) }
        runner.index = index; runner.start()
        defer { runner.stop() }
        try #require(await eventually(30) { batches.last?.done == true })
        let initial = batches.count
        let updated = index.status.updated
        try s.file("root/unrelated.txt", "another folder changed")
        try #require(await eventually(30) { index.status.updated != updated })
        try await Task.sleep(for: .milliseconds(300))
        #expect(batches.count == initial)

        try s.file("root/sub/no-0.txt", "modified")
        try #require(await eventually(30) { batches.last?.items.first(where: { $0.name == "no-0.txt" })?.size == 8 })
        #expect(batches.last?.items.count == 80)
        try s.file("root/sub/no-new.txt")
        try #require(await eventually(30) { batches.last?.items.count == 81 })
        try FileManager.default.removeItem(at: s.path("root/sub/no-new.txt"))
        try #require(await eventually(30) { batches.last?.items.count == 80 })
        #expect(batches.dropFirst(initial).allSatisfy { $0.done && $0.items.count >= 80 })
        let settled = batches.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(batches.count == settled)
    }

}

@MainActor @Suite(.isolatedSettings) struct SearchResultMetadataTests {
    @Test func sameURLsWithChangedMetadataAreSortedAgainAndKeepSelection() async throws {
        let s = try Scratch()
        let first = FileItem(url: s.path("first.txt"), name: "first.txt", isDirectory: false, size: 1)
        let second = FileItem(url: s.path("second.txt"), name: "second.txt", isDirectory: false, size: 2)
        let changed = FileItem(url: first.url, name: first.name, isDirectory: false, size: 3)
        let model = DirectoryModel(location: s.url)
        model.props.sortRole = .size
        model.searchResults = [first, second]
        model.selection = [first.url]
        var applied = false
        model.sortSearchResults([changed, second]) { apply in
            apply(); applied = true
        }
        try #require(await eventually { applied })
        #expect(model.rows.map(\.item.size) == [2, 3])
        #expect(model.selection == [first.url])
        // Also cover the synchronous growing-results shortcut.
        let third = FileItem(url: s.path("third.txt"), name: "third.txt", isDirectory: false, size: 4)
        model.searchResults = [first, second, third]
        #expect(model.rows.map(\.item.size) == [1, 2, 4])
        #expect(model.selection == [first.url])
    }
}
