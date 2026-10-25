import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import os

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct CustomToolsStoreIsolationTests {
    @Test func aQueuedWarmupCannotLoadTheReplacementStore() async throws {
        let original = Settings.store, replacement = MemoryDefaults()
        let oldTool = CustomTool(name: "Old store", executable: "/usr/bin/true", arguments: [])
        let newTool = CustomTool(name: "Existing", executable: "/usr/bin/true", arguments: [])
        original.set(try CustomToolDocument(tools: [oldTool]).encoded(), forKey: "customTools")
        replacement.set(try CustomToolDocument(tools: [newTool]).encoded(), forKey: "customTools")
        defer { Settings.store = original }
        #expect(Settings.shared.customToolsIfLoaded.isEmpty)
        let queue = DispatchQueue(label: "porpoise.test.old-custom-tools-warmup")
        queue.suspend()
        var suspended = true, completed = false
        defer { if suspended { queue.resume() } }
        Settings.shared.prepareCustomToolsAfterFirstWindow(on: queue) { completed = true }
        Settings.store = replacement
        queue.resume(); suspended = false
        try #require(await eventually { completed })
        #expect(Settings.shared.customToolsIfLoaded.isEmpty)
        #expect(Settings.shared.customTools == [newTool])
    }

    @Test func completionCannotNotifyObserversToLoadAReplacementStore() async throws {
        let original = Settings.store, replacement = MemoryDefaults()
        let oldTool = CustomTool(name: "Old store", executable: "/usr/bin/true", arguments: [])
        let newTool = CustomTool(name: "Existing", executable: "/usr/bin/true", arguments: [])
        original.set(try CustomToolDocument(tools: [oldTool]).encoded(), forKey: "customTools")
        replacement.set(try CustomToolDocument(tools: [newTool]).encoded(), forKey: "customTools")
        defer { Settings.store = original }
        let staleNotices = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { note in
            guard note.object as? String == "customTools", Settings.store === replacement else { return }
            staleNotices.withLock { $0 += 1 }
            // A live palette/menu observer reads explicit settings when a custom-tools refresh reaches it.
            _ = Settings.shared.customTools
        }
        defer { NotificationCenter.default.removeObserver(token) }
        var completed = false
        Settings.shared.prepareCustomToolsAfterFirstWindow(on: DispatchQueue(label: "porpoise.test.old-custom-tools-notice")) {
            Settings.store = replacement
            completed = true
        }
        try #require(await eventually { completed })
        #expect(staleNotices.withLock { $0 } == 0)
        #expect(Settings.shared.customToolsIfLoaded.isEmpty)
        #expect(Settings.shared.customTools == [newTool])
    }
}
