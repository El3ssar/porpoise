import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Background work (index crawls, adb polls) must start while other work keeps every core busy, as a full test run
/// does on CI's 3-core runner. Utility work on the shared GCD pool got no thread then, and stayed queued.
@MainActor @Suite(.serialized) struct BusyPoolTests {
    /// Keeps a default-QoS GCD worker spinning per core until the returned function is called.
    private func occupyEveryCore() -> () -> Void {
        let stop = StopFlag()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            DispatchQueue.global().async {
                while !stop.isSet { _ = (0..<1000).reduce(0, +) }
            }
        }
        return { stop.set() }
    }

    @Test func anIndexIsBuiltWhileEveryCoreIsBusy() async throws {
        let s = try Scratch()
        try s.file("root/a.txt")
        let suite = "PorpoiseIndexTests.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let index = SearchIndex(directory: s.path("store"), defaults: try #require(UserDefaults(suiteName: suite)))
        var config = IndexConfiguration()
        config.enabled = true
        config.roots = [s.path("root").path]
        let release = occupyEveryCore()
        defer { release() }
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        // Was "Index queued for crawl" for as long as the cores stayed busy.
        #expect(await eventually(15) { !index.status.building && index.status.updated != nil }, "\(index.status)")
        release()
        #expect(index.search("a", scope: s.path("root"))?.paths.count == 1)
    }

    @Test func phonesArePolledWhileEveryCoreIsBusy() async throws {
        let s = try Scratch()
        let adb = try RecordingTool()
        try adb.reply("List of devices attached\nR58N123 device usb:1-1 product:x model:Pixel_9 device:o1s\n")
        let m = PlacesModel(storeURL: nil)
        m.cloudStorageRoot = s.path("none")
        m.adbTool = { adb.path }
        defer { m.isActive = false }
        let release = occupyEveryCore()
        defer { release() }
        m.refreshDetected()
        #expect(await eventually(15) { m.detected.contains { $0.title == "Pixel 9" } })
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

/// Asking AVFoundation whether a file plays needs no free cooperative thread: synchronous work may hold them all
/// (a preview waited 49s to start in a loaded run). Not on the main actor: the answer comes there while this test's
/// own thread, like the others, is held.
@Suite struct BusyCooperativePoolTests {
    @Test func aVideoPreviewAnswersWhileEveryCooperativeThreadIsTaken() throws {
        let s = try Scratch()
        let file = try s.file("not a video.mkv", "plain text")
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let answered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<blockers { Task.detached { hold(release) } }
        defer { for _ in 0..<blockers { release.signal() } }
        p.playableURL(for: file, owner: NSObject()) { _ in answered.signal() }
        #expect(answered.wait(timeout: .now() + 15) == .success)
    }
}

/// Holds a cooperative thread until `release` is signalled.
private func hold(_ release: DispatchSemaphore) { release.wait() }
