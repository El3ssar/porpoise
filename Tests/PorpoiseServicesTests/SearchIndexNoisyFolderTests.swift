import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Folders that builds, apps and macOS keep rewriting stay out of the index by default (W-129): on a developer's Mac
/// they were nearly all of what FSEvents reported (87 % build folders, 10 % the index's own saves).
@MainActor struct SearchIndexNoisyFolderTests {
    final class Defaults {
        let name = "PorpoiseIndexNoisyTests.\(UUID())"
        let store: UserDefaults
        init() { store = UserDefaults(suiteName: name)! }
        deinit { store.removePersistentDomain(forName: name) }
    }

    @Test func buildOutputIsNotIndexedUnlessAsked() async throws {
        let s = try Scratch()
        try s.file("root/app/Sources/main.swift")
        try s.file("root/app/.build/debug/main.swift.o")
        try s.file("root/xcode/DerivedData/Build/Products/built.o")
        let defaults = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: defaults.store)
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        #expect(config.excludeBuildOutput && config.excludeSystemFolders)
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        try await index.waitUntilReady()
        #expect(index.search("main.swift", scope: s.path("root"))?.paths.count == 1)
        #expect(index.search("built.o", scope: s.path("root"))?.paths.isEmpty == true)
        #expect(index.search(".build", scope: s.path("root"))?.paths.isEmpty == true)
        // Changes in them are dropped as they arrive.
        try s.file("root/app/.build/debug/fresh-object.o")
        try s.file("root/app/Sources/fresh-source.swift")
        #expect(await eventually { index.search("fresh-source", scope: s.path("root"))?.paths.count == 1 })
        #expect(index.search("fresh-object", scope: s.path("root"))?.paths.isEmpty == true)
        config.excludeBuildOutput = false
        index.configure(config)
        try await index.waitUntilReady()
        #expect(index.search("main.swift", scope: s.path("root"))?.paths.count == 2)
        #expect(index.search("built.o", scope: s.path("root"))?.paths.count == 1)
    }

    @Test func systemFoldersAreTheLibraryApartFromCloudDrivesAndTheTrash() {
        let home = IndexConfiguration.home
        var config = IndexConfiguration()
        config.roots = [home]
        #expect(config.inSystemFolder(home + "/Library/Caches/com.example/file"))
        #expect(config.inSystemFolder(home + "/Library/Application Support/Porpoise/SearchIndex/x.idx"))
        #expect(config.inSystemFolder(home + "/Library/Preferences"))
        #expect(config.inSystemFolder(home + "/.Trash/old.txt"))
        #expect(!config.inSystemFolder(home + "/Library"))
        #expect(!config.inSystemFolder(home + "/Library/CloudStorage/GoogleDrive-a@example.com/My Drive/report.pdf"))
        #expect(!config.inSystemFolder(home + "/Library/Mobile Documents/com~apple~CloudDocs/notes.txt"))
        #expect(!config.inSystemFolder(home + "/Documents/Library/Caches/kept.txt"))
        #expect(!config.inSystemFolder(home + "/LibraryNotes/x"))
        // A folder chosen inside one is indexed all the same.
        config.roots = [home, home + "/Library/Application Support/Notes App"]
        #expect(!config.inSystemFolder(home + "/Library/Application Support/Notes App/note.txt"))
        #expect(config.inSystemFolder(home + "/Library/Caches/x"))
        config.roots = [home + "/.Trash"]
        #expect(!config.inSystemFolder(home + "/.Trash/old.txt"))
        config.excludeSystemFolders = false
        config.roots = [home]
        #expect(!config.inSystemFolder(home + "/Library/Caches/x"))
    }

    /// Settings saved by 0.8.5 and earlier have neither switch: both come on.
    @Test func olderSavedSettingsGetTheNewDefaults() throws {
        let saved = #"""
            {"enabled":true,"roots":["/Users/someone"],"exclusions":["/x"],"excludeGitObjects":false,"excludeNodeModules":true,
            "content":true}
            """#
        let config = try JSONDecoder().decode(IndexConfiguration.self, from: Data(saved.utf8))
        #expect(config.enabled && config.roots == ["/Users/someone"] && config.exclusions == ["/x"])
        #expect(!config.excludeGitObjects && config.excludeNodeModules && config.content)
        #expect(config.excludeBuildOutput && config.excludeSystemFolders)
        var changed = config
        changed.excludeBuildOutput = false
        #expect(try JSONDecoder().decode(IndexConfiguration.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(try JSONDecoder().decode(IndexConfiguration.self, from: Data("{}".utf8)) == IndexConfiguration())
    }

    /// A snapshot saved by 0.8.5 holds the build folders: it is built again rather than loaded.
    @Test func anOlderSnapshotIsBuiltAgain() async throws {
        let s = try Scratch()
        try s.file("root/kept.txt")
        try s.file("root/app/.build/old.o")
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        config.excludeBuildOutput = false
        let first = Defaults()
        let index = SearchIndex(directory: s.path("store"), defaults: first.store)
        index.configure(config)
        try await index.waitUntilReady()
        let manifest = s.path("store/manifest.json")
        #expect(await eventually { FileManager.default.fileExists(atPath: manifest.path) })
        index.configure(IndexConfiguration())
        // As 0.8.5 wrote it: no version, no new switches, the build folder indexed.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["version"] = nil
        var saved = try #require(json["configuration"] as? [String: Any])
        saved["excludeBuildOutput"] = nil
        saved["excludeSystemFolders"] = nil
        json["configuration"] = saved
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let second = Defaults()
        let restored = SearchIndex(directory: s.path("store"), defaults: second.store)
        config.excludeBuildOutput = true
        restored.configure(config)
        defer { restored.configure(IndexConfiguration()) }
        try await restored.waitUntilReady()
        #expect(restored.search("kept", scope: s.path("root"))?.paths.count == 1)
        #expect(restored.search("old.o", scope: s.path("root"))?.paths.isEmpty == true)
    }
}
