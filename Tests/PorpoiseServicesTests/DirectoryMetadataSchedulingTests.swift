import Foundation
import os
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct DirectoryMetadataSchedulingTests {
    private func mainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func repeatedLayoutMissesShareOneInFlightRead() async throws {
        let scratch = try Scratch("metadata-in-flight")
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let item = FileItem(url: scratch.path("item.txt"), name: "item.txt", isDirectory: false)
        let gate = DispatchSemaphore(value: 0)
        let counts = OSAllocatedUnfairLock(initialState: (tags: 0, cloud: 0))
        model.readItemMetadataForTesting = { _, tags in
            if tags {
                let read = counts.withLock { $0.tags += 1; return $0.tags }
                if read == 1 { gate.wait() }
            } else {
                counts.withLock { $0.cloud += 1 }
            }
            return (tags ? [FinderTags.Tag(name: "Red", color: 6)] : nil, (.local, false))
        }
        defer { gate.signal() }
        #expect(model.shownTags(for: item).isEmpty)
        try #require(await eventually { counts.withLock { $0.tags } == 1 })
        // Simulate later asynchronous layout batches/redraws while the first disk read is held.
        for _ in 0..<8 {
            #expect(model.shownTags(for: item).isEmpty)
            #expect(model.shownCloud(for: item).state == .local)
            await mainTurn()
        }
        gate.signal()
        try #require(await eventually { model.shownTags(for: item).map(\.name) == ["Red"] })
        // Cloud refresh is queued after any duplicate tag reads, giving the serial worker a barrier.
        model.refreshCloud()
        try #require(await eventually { counts.withLock { $0.cloud } == 1 })
        #expect(counts.withLock { $0.tags } == 1)
        #expect(model.shownTags(for: item).map(\.name) == ["Red"])
    }

    @Test(arguments: [false, true])
    func staleCompletionCannotReleaseANewerReadsReservation(reload: Bool) async throws {
        let scratch = try Scratch("metadata-generation")
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let item = FileItem(url: scratch.path("item.txt"), name: "item.txt", isDirectory: false)
        let oldGate = DispatchSemaphore(value: 0), newGate = DispatchSemaphore(value: 0)
        let counts = OSAllocatedUnfairLock(initialState: (tags: 0, cloud: 0))
        model.readItemMetadataForTesting = { _, tags in
            guard tags else {
                counts.withLock { $0.cloud += 1 }
                return (nil, (.local, false))
            }
            let read = counts.withLock { $0.tags += 1; return $0.tags }
            if read == 1 { oldGate.wait() }
            if read == 2 { newGate.wait() }
            return ([FinderTags.Tag(name: read == 1 ? "Old" : "New", color: 0)], (.local, false))
        }
        defer { oldGate.signal(); newGate.signal() }
        var publications = 0
        model.onMetadataLoaded = { publications += 1 }
        _ = model.shownTags(for: item)
        try #require(await eventually { counts.withLock { $0.tags } == 1 })
        if reload {
            model.reload()
            try #require(await eventually { !model.isLoading })
        } else {
            model.refreshTags()
        }
        _ = model.shownTags(for: item)
        await mainTurn()
        oldGate.signal()
        try #require(await eventually { counts.withLock { $0.tags } == 2 })
        await mainTurn()  // The old completion has arrived while the new read remains held.
        #expect(publications == 0 && model.shownTags(for: item).isEmpty)
        for _ in 0..<8 {
            _ = model.shownTags(for: item)
            await mainTurn()
        }
        newGate.signal()
        try #require(await eventually { model.shownTags(for: item).map(\.name) == ["New"] })
        #expect(publications == 1)
        model.refreshCloud()
        try #require(await eventually { counts.withLock { $0.cloud } == 1 })
        #expect(counts.withLock { $0.tags } == 2)
    }
}
