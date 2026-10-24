import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct StartupDeferralTests {
    private final class CountingDefaults: UserDefaults {
        private let lock = NSLock()
        private var reads: [Bool] = []
        var toolReads: [Bool] { lock.lock(); defer { lock.unlock() }; return reads }
        override func data(forKey key: String) -> Data? {
            if key == "customTools" { lock.lock(); reads.append(Thread.isMainThread); lock.unlock() }
            return super.data(forKey: key)
        }
    }

    @Test func automaticMenusDoNotReadUnloadedToolsAndWorkerPreparationPreservesExactAPI() async throws {
        let suite = "porpoise-startup-tools-" + UUID().uuidString
        let store = try #require(CountingDefaults(suiteName: suite))
        let previous = Settings.store
        Settings.store = store
        defer { Settings.store = previous; store.removePersistentDomain(forName: suite) }
        let tools = CustomToolDocument.examples
        store.set(try CustomToolDocument(tools: tools).encoded(), forKey: "customTools")
        for _ in 0..<20 { #expect(Settings.shared.customToolsIfLoaded.isEmpty) }
        #expect(store.toolReads.isEmpty)
        var rebuilt = false
        let observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { note in
            guard note.object as? String == "customTools" else { return }
            #expect(Thread.isMainThread)
            #expect(Settings.shared.customToolsIfLoaded == tools)
            #expect(Settings.shared.customTools == tools)
            rebuilt = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var completed = false
        Settings.shared.prepareCustomToolsAfterFirstWindow {
            #expect(Thread.isMainThread)
            completed = true
        }
        try #require(await eventually { completed })
        // Preparation must do the first read off-main. Its notification can immediately rebuild warm consumers,
        // whose legitimate preference reads must not be mistaken for eager loading before preparation.
        #expect(store.toolReads.first == false)
        #expect(rebuilt)
        #expect(Settings.shared.customToolsIfLoaded == tools)
        #expect(Settings.shared.customTools == tools)
        // Once loaded, an explicit preference edit is reflected by menu reconstruction too.
        store.removeObject(forKey: "customTools")
        #expect(Settings.shared.customToolsIfLoaded.isEmpty)
    }

    @Test func emptyPreparationCompletesWithoutRebuildingMenus() async throws {
        var refreshes = 0, completed = false
        let observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { note in
            if note.object as? String == "customTools" { refreshes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        Settings.shared.prepareCustomToolsAfterFirstWindow { completed = true }
        try #require(await eventually { completed })
        #expect(refreshes == 0)
    }

    @Test func replacementStoresStartColdAfterPreviousStoresAreReleased() throws {
        let previous = Settings.store, tools = CustomToolDocument.examples
        let document = try CustomToolDocument(tools: tools).encoded()
        defer { Settings.store = previous }
        for _ in 0..<128 {
            autoreleasepool {
                let replacement = MemoryDefaults()
                Settings.store = replacement
                replacement.set(document, forKey: "customTools")
                #expect(Settings.shared.customToolsIfLoaded.isEmpty)
                #expect(Settings.shared.customTools == tools)
                Settings.store = previous
            }
        }
    }

    private func scanCount(_ root: URL) async throws -> Int {
        let canonical = URL(fileURLWithPath: FilePath.canonical(root.path))
        return try await awaitCallback("Git startup queue barrier") { continuation in
            GitStatusService.shared.scanCount(for: canonical) { continuation.resume(returning: $0) }
        }
    }

    @Test func discoveryWaitsOneMainTurnAndSkipsStaleNavigation() async throws {
        let (first, second) = try await Task.detached {
            let first = try LocalGitFixture(), second = try LocalGitFixture()
            try first.scratch.file("first", "x"); try first.record()
            try second.scratch.file("second", "x"); try second.record()
            return (first, second)
        }.value
        let model = DirectoryModel(location: first.url, prefetchFolders: false)
        model.reload(); model.setLocation(second.url)
        // Enqueue both background queue barriers before yielding this main turn. Eager discovery would precede them.
        let counts: [Int] = try await awaitCallback("pre-discovery barriers") { continuation in
            var counts = [Int?](repeating: nil, count: 2)
            for (index, folder) in [first.url, second.url].enumerated() {
                GitStatusService.shared.scanCount(for: URL(fileURLWithPath: FilePath.canonical(folder.path))) { count in
                    counts[index] = count
                    if counts.allSatisfy({ $0 != nil }) { continuation.resume(returning: counts.compactMap { $0 }) }
                }
            }
        }
        #expect(counts == [0, 0])
        try #require(await eventually { !model.isLoading && model.gitStatus != nil })
        #expect(model.gitStatus?.root.path == FilePath.canonical(second.url.path))
        #expect(try await scanCount(first.url) == 0)
        #expect(try await scanCount(second.url) == 1)
    }

    @Test func disabledStatusAndDestroyedModelsDoNotStartQueuedDiscovery() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture(); try f.scratch.file("f", "x"); try f.record(); return f
        }.value
        var model: DirectoryModel? = DirectoryModel(location: f.url, prefetchFolders: false)
        model?.reload()
        let wasReleased = { [weak model] in model == nil }
        model = nil
        let disabled = DirectoryModel(location: f.url, prefetchFolders: false)
        disabled.reload()
        Settings.shared.showGitStatus = false
        try #require(await eventually { !disabled.isLoading })
        #expect(wasReleased())
        #expect(try await scanCount(f.url) == 0)
        #expect(disabled.gitStatus == nil)
    }
}
