import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Status strings, readiness, saved settings, unreadable entries and the refresh paths that re-walk a whole root.
@MainActor struct SearchIndexCoverageTests {
    /// Crawls and FSEvents can take seconds in a full parallel run: waits end as soon as their condition holds.
    static let liveWait: TimeInterval = 30

    /// A private settings domain, removed when the test ends.
    final class Defaults {
        let name = "PorpoiseIndexCoverageTests.\(UUID())"
        let store: UserDefaults
        init() { store = UserDefaults(suiteName: name)! }
        deinit { store.removePersistentDomain(forName: name) }
    }

    private func configuration(_ s: Scratch) -> IndexConfiguration {
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        config.exclusions = [s.path("root/private").path]
        return config
    }
    /// The hint compares paths as given (no filesystem calls): scratch URLs lack the /private that roots carry.
    private func canonical(_ s: Scratch, _ relative: String) -> URL {
        URL(fileURLWithPath: FilePath.canonical(s.path(relative).path))
    }
    /// The saved manifest's patch count for the first root, nil while there is no manifest.
    private func savedPatches(_ s: Scratch) -> Int? {
        guard let data = try? Data(contentsOf: s.path("store/manifest.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let roots = json["roots"] as? [[String: Any]], let patches = roots.first?["patches"] as? [Any]
        else { return nil }
        return patches.count
    }

    @Test func savedConfigurationIsLoadedAndStartBuildsIt() async throws {
        let s = try Scratch()
        try s.file("root/saved-name.txt")
        let defaults = Defaults()
        defaults.store.set(try JSONEncoder().encode(configuration(s)), forKey: "searchIndex.configuration")
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        defer { index.configure(IndexConfiguration()) }
        #expect(index.configuration == configuration(s))
        #expect(index.statusText == "Index off")
        #expect(!index.hasReadySnapshot(for: canonical(s, "root")))
        index.start()
        let early = index.statusText
        #expect(early == "Index building…" || early.hasPrefix("Index: "))
        try await index.waitUntilReady(timeout: Self.liveWait)
        #expect(index.statusText.hasPrefix("Index: 2 items, updated "))
        #expect(!index.statusText.contains(" · "))
        #expect(index.search("saved-name", scope: s.path("root"))?.paths.count == 1)
        #expect(index.hasReadySnapshot(for: canonical(s, "root")))
        #expect(!index.hasReadySnapshot(for: canonical(s, "root/private")))
        #expect(!index.hasReadySnapshot(for: canonical(s, "")))
    }

    @Test func statusTextWithoutASnapshot() throws {
        let s = try Scratch()
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        var config = IndexConfiguration()
        config.enabled = true
        index.configure(config)
        #expect(index.statusText == "Select folders to index")
        #expect(!index.status.building)
        index.configure(IndexConfiguration())
        #expect(index.statusText == "Index off")
    }

    @Test func unreadableEntriesWarnAndKeepThoseScopesOnTheFallback() async throws {
        let s = try Scratch()
        try s.file("root/locked/inside.txt")
        try s.file("root/open/visible.txt")
        // Listable but not searchable: the walk sees the name, but lstat of the entry is refused.
        let locked = s.path("root/locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        index.configure(configuration(s))
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        #expect(index.status.warning == "Some folders unreadable; regular search used for those scopes")
        #expect(index.statusText.hasSuffix(" · Some folders unreadable; regular search used for those scopes"))
        #expect(!index.hasReadySnapshot(for: canonical(s, "root")))
        #expect(!index.hasReadySnapshot(for: canonical(s, "root/locked")))
        #expect(index.hasReadySnapshot(for: canonical(s, "root/open")))
        #expect(index.search("visible", scope: s.path("root")) == nil)
        #expect(index.search("visible", scope: s.path("root/open"))?.paths.count == 1)
    }

    @Test func damagedSnapshotsAreRebuilt() async throws {
        let s = try Scratch()
        try s.file("root/kept.txt")
        let config = configuration(s)
        let first = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: first.store)
        index.configure(config)
        try await index.waitUntilReady(timeout: Self.liveWait)
        try #require(await eventually(Self.liveWait) { savedPatches(s) != nil })
        index.configure(IndexConfiguration())
        let manifestURL = s.path("store/manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var manifest = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var roots = try #require(manifest["roots"] as? [[String: Any]])
        let base = try #require(roots.first?["base"] as? String)
        // A snapshot that isn't one, and a manifest naming a file outside the store: both are walked again.
        try Data("not an index".utf8).write(to: s.path("store/\(base)"))
        roots[0]["base"] = "../outside.idx"
        manifest["roots"] = roots
        let tampered = try JSONSerialization.data(withJSONObject: manifest)
        for damage in [original, tampered] {
            try damage.write(to: manifestURL)
            let defaults = Defaults()
            let restored = SearchIndex(directory: s.path("store"), defaults: defaults.store)
            restored.configure(config)
            try await restored.waitUntilReady(timeout: Self.liveWait)
            #expect(restored.search("kept", scope: s.path("root"))?.paths.count == 1)
            // The rebuilt snapshot is saved over the damaged one before the next round damages it again.
            try #require(await eventually(Self.liveWait) { (try? Data(contentsOf: manifestURL)) != damage })
            restored.configure(IndexConfiguration())
        }
    }

    @Test func aStoreThatCannotBeWrittenIsReported() async throws {
        let s = try Scratch()
        try s.file("root/a.txt")
        try s.file("store", "a file where the store folder should be")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        index.configure(configuration(s))
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        try #require(await eventually(Self.liveWait) { index.status.warning?.hasPrefix("Index could not be saved: ") == true })
        #expect(index.statusText.contains(" · Index could not be saved: "))
        #expect(index.search("a.txt", scope: s.path("root"))?.paths.count == 1)
    }

    @Test func nestedExcludedAndSeveralRoots() async throws {
        let s = try Scratch()
        try s.file("root/inner/nested.txt")
        try s.file("second/other.txt")
        try s.file("root/private/hidden.txt")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        var config = configuration(s)
        config.roots = [s.path("second").path, s.path("root/inner").path, s.path("root").path, s.path("root/private").path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        // The nested roots fold into the root that holds them.
        #expect(index.configuration.roots == [FilePath.canonical(s.path("root").path), FilePath.canonical(s.path("second").path)])
        try await index.waitUntilReady(timeout: Self.liveWait)
        #expect(index.search("nested", scope: s.path("root"))?.paths.count == 1)
        #expect(index.search("other", scope: s.path("second"))?.paths.count == 1)
        // A root that is itself excluded contributes nothing.
        config.roots = [s.path("root/private").path]
        index.configure(config)
        try await index.waitUntilReady(timeout: Self.liveWait)
        #expect(index.status.count == 0)
        #expect(index.search("hidden", scope: s.path("root/private")) == nil)
    }

    @Test func contentSearchStopsAtItsLimitAndOnCancel() async throws {
        let s = try Scratch()
        for n in 0..<3 { try s.file("root/note-\(n).txt", "first line\nshared phrase \(n)") }
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        var config = configuration(s)
        config.content = true
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        let root = s.path("root")
        let all = index.search("shared phrase", scope: root, contents: true)
        #expect(all?.paths.count == 3)
        #expect(all?.snippets.count == 3)
        #expect(index.search("shared phrase", scope: root, contents: true, limit: 1)?.paths.count == 1)
        #expect(index.search("absent phrase", scope: root, contents: true)?.paths.isEmpty == true)
        // Cancelled once the name scan is done: the content pass gives up with nothing.
        var calls = 0
        let cancelled = index.search("shared phrase", scope: root, contents: true) {
            calls += 1
            return calls > 2
        }
        #expect(cancelled?.paths.isEmpty == true)
    }

    @Test func invalidQueriesReportTheirErrorAndContentNeedsContentIndexing() async throws {
        let s = try Scratch()
        try s.file("root/a.txt", "words")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        index.configure(configuration(s))
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        let result = index.search("\"unclosed", scope: s.path("root"))
        #expect(result?.paths.isEmpty == true)
        #expect(result?.error == "Invalid search: unclosed quote")
        #expect(index.search("words", scope: s.path("root"), contents: true) == nil)
    }

    @Test func aChangeToTheRootItselfRewalksTheWholeRoot() async throws {
        let s = try Scratch()
        try s.folder("root")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        index.configure(configuration(s))
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        try s.file("root/patched.txt")
        // A new file is saved as a patch over the base.
        try #require(await eventually(Self.liveWait) { (savedPatches(s) ?? 0) > 0 })
        #expect(index.search("patched", scope: s.path("root"))?.paths.count == 1)
        // An event naming the root walks it again into a new base without patches.
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: s.path("root").path)
        try #require(await eventually(Self.liveWait) { savedPatches(s) == 0 })
        #expect(index.search("patched", scope: s.path("root"))?.paths.count == 1)
        #expect(index.status.count == 2)
    }

    @Test func aLargeReplayedBatchIsFoldedIntoItsFolders() async throws {
        let s = try Scratch()
        try s.file("root/before.txt")
        let first = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: first.store)
        index.configure(configuration(s))
        try await index.waitUntilReady(timeout: Self.liveWait)
        try #require(await eventually(Self.liveWait) { savedPatches(s) != nil })
        let config = index.configuration
        index.configure(IndexConfiguration())
        // Created while no index runs: FSEvents replays them together from the saved cursor.
        for n in 0..<200 { try s.file("root/bulk/replayed-\(n).txt") }
        let second = Defaults()
        let restored = SearchIndex(directory: s.path("store"), defaults: second.store)
        restored.configure(config)
        defer { restored.configure(IndexConfiguration()) }
        try await restored.waitUntilReady(timeout: Self.liveWait)
        try #require(
            await eventually(Self.liveWait) { restored.search("replayed-", scope: s.path("root"))?.paths.count == 200 })
        try #require(await eventually(Self.liveWait) { restored.status.count == 203 })
    }

    @Test func manyPatchesAreCompactedIntoANewBase() async throws {
        let s = try Scratch()
        try s.folder("root")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        index.configure(configuration(s))
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady(timeout: Self.liveWait)
        // Small rounds keep each event batch small, so every new file becomes its own patch until 1024 of them.
        var created = 0
        for _ in 0..<33 {
            for _ in 0..<32 {
                try s.file("root/drip-\(created).txt")
                created += 1
            }
            let expected = created
            // The count is cheap to read; a search over a thousand patches every poll would hold up the main actor.
            try #require(await eventually(Self.liveWait) { index.status.count == expected + 1 })
        }
        try #require(await eventually(Self.liveWait) { (savedPatches(s) ?? .max) < 1024 })
        #expect(index.status.count == created + 1)
        #expect(index.search("drip-", scope: s.path("root"))?.paths.count == created)
    }
}

/// Off the main actor: attaching a disk image and walking take a while and must not hold up other suites.
struct IndexCrawlerCoverageTests {
    @Test func crawlerSkipsMissingRootsSpecialFilesAndOtherVolumes() throws {
        let s = try Scratch()
        try s.file("root/plain.txt")
        #expect(mkfifo(s.path("root/pipe").path, 0o600) == 0)
        let volume = try DiskImage(name: "IndexCrawl", in: s)
        try Data().write(to: volume.volume.appendingPathComponent("on-image.txt"))
        try s.symlink("root/volume-link", to: volume.volume.path)
        #expect(IndexCrawler.crawl(s.path("missing").path, exclusions: []).count == 0)
        let table = IndexCrawler.crawl(s.path("root").path, exclusions: [], content: true)
        #expect(try table.search(IndexQuery("pipe")).isEmpty)
        #expect(try table.search(IndexQuery("plain")).count == 1)
        // The image is mounted inside the scratch folder; a crawl from there must not enter it.
        let outer = IndexCrawler.crawl(s.url.path, exclusions: [])
        #expect(try outer.search(IndexQuery("on-image")).isEmpty)
        #expect(try outer.search(IndexQuery("plain")).count == 1)
    }
}
