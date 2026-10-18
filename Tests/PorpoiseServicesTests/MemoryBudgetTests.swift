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

    /// 50 000 changes in bursts, as FSEvents reports a busy home folder: each costs the same to take in, however many
    /// came before, and what waits for the next update stays bounded. In v0.8.5 every batch copied the whole set of
    /// waiting changes, so the CPU spent per change grew with the stream (W-129).
    @MainActor @Test func aLongStreamOfChangesCostsTheSameForEachChange() async throws {
        let s = try Scratch()
        let root = try s.folder("root").path
        let suite = "PorpoiseIndexTests.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: try #require(UserDefaults(suiteName: suite)))
        // Only collected, never applied: this measures taking changes in.
        index.updateDelay = 3600
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [root]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady()
        // As FSEvents reports them: real paths (/private/var, not /var).
        let real = try #require(index.configuration.roots.first)
        let bursts = 50, perBurst = 1000, batch = 5
        var seconds: [Double] = []
        var settled = 0
        var event: UInt64 = 1
        for b in 0..<bursts {
            let paths = (0..<perBurst).map { real + "/d\(($0 + b) % 200)/f\(b)-\($0).txt" }
            let start = DispatchTime.now().uptimeNanoseconds
            for first in stride(from: 0, to: perBurst, by: batch) {
                index.receive(Array(paths[first..<first + batch]), event: event)
                event += 1
            }
            seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            if b == 9 { settled = Self.bytesInUse() }
        }
        // Ten bursts each, so that the occasional fold is counted in both.
        let early = seconds[2..<12].reduce(0, +) / 10, late = seconds[40..<50].reduce(0, +) / 10
        #expect(late < early * 2, "a burst took \(early)s early in the stream and \(late)s late")
        #expect(index.queuedPaths <= SearchIndex.Changes.foldLimit * 2, "\(index.queuedPaths) changed paths wait")
        let grown = Self.bytesInUse() - settled
        #expect(grown < 3 << 20, "malloc grew by \(grown >> 10) KB over the last 40 000 changes")
    }
}
