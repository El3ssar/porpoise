import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Memory a long session must not gain. v0.8.3 reached 2.0 GB in 8 minutes with the index on: a tree that kept
/// changing kept the index's queue busy, so what Foundation autoreleased while saving and updating the index was
/// never freed (W-125). What a test process holds is shared by every test running in it, so these run alone, like
/// BusyPoolTests (scripts/test-with-watchdog.sh); by hand: `PORPOISE_TESTS_ALONE=1 swift test --filter MemoryBudgetTests`.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PORPOISE_TESTS_ALONE"] == "1", "runs alone: scripts/test-with-watchdog.sh"))
struct MemoryBudgetTests {
    /// Bytes malloc has handed out and not had back, in every zone.
    static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    @MainActor @Test func anIndexFollowingABusyTreeStaysWithinItsBudget() async throws {
        let s = try Scratch()
        // Changes everywhere at once (a build, an app saving its state), and in the root itself (a settings file in
        // the home folder).
        let folders = 120
        for f in 0..<folders {
            let folder = try s.folder("root/d\(f)/sub").path
            for n in 0..<400 { FileManager.default.createFile(atPath: folder + "/file\(n).txt", contents: Data("x".utf8)) }
        }
        let suite = "PorpoiseIndexTests.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: try #require(UserDefaults(suiteName: suite)))
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady()
        // Settle what starting took, then measure what keeping up costs.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = Self.bytesInUse()
        let rounds = 150
        for round in 0..<rounds {
            for f in stride(from: round % 3, to: folders, by: 3) {
                try "\(round)".write(to: s.path("root/d\(f)/sub/file\(round % 40).txt"), atomically: false, encoding: .utf8)
            }
            try "\(round)".write(to: s.path("root/settings.json"), atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let last = "root/d0/sub/last-change-\(UUID().uuidString).txt"
        try s.file(last)
        #expect(await eventually(30) { index.search("last-change", scope: s.path("root"))?.paths.count == 1 }, "\(index.status)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let grown = Self.bytesInUse() - before
        // 6 000 changes to a 48 000-file tree: before W-125 malloc kept 79 MB more; since, 2 to 8 MB.
        #expect(grown < 24 << 20, "malloc grew by \(grown >> 20) MB while the index followed \(rounds) rounds of changes")
    }
}
