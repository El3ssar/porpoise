import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import os

@testable import PorpoiseServices

/// Background work (index crawls, adb polls, video previews) must start while other work keeps every core or every
/// cooperative thread busy, as a full test run does on CI's 3-core runner. Utility work on the shared GCD pool got no
/// thread then, and stayed queued.
///
/// These tests take what the whole test process shares, so they run alone: while one holds every core or every
/// cooperative thread, the other suites' tests stand still, and their waits run out (a 5 s wait expired while a preview
/// held the pool, and its test then changed a file a download had not read yet: W-111). scripts/test-with-watchdog.sh
/// runs them in a pass of their own, before the others; by hand:
/// `PORPOISE_TESTS_ALONE=1 swift test --filter BusyPoolTests`.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PORPOISE_TESTS_ALONE"] == "1", "runs alone: scripts/test-with-watchdog.sh"))
struct BusyPoolTests {
    /// Range responses must keep moving independently of the pool: their send-idle deadline is real time. A response
    /// waiting for a held cooperative thread never moves, so it fails by that deadline, or by the wait below; the
    /// deadline is long so that the spinning cores alone can't trip it.
    @MainActor @Test(arguments: Self.priorities) func aRangeResponseFinishesWhileEveryCooperativeThreadIsTaken(_ priority: TaskPriority) throws {
        let server = LocalFileServer()
        server.sendTimeout = 30
        defer { server.stop() }
        let url = try #require(
            server.start(
                source: .init(
                    size: 10, contentType: "video/mp4",
                    read: { _ in
                        // A 10 ms asynchronous read, completed from a queue of its own like a network one. Not
                        // Task.sleep or a global queue: those wait for the threads the busy priority holds.
                        await withCheckedContinuation { continuation in
                            Self.readQueue.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
                        }
                        return Data(repeating: 42, count: 10)
                    })))
        try expectResponseWhileCooperativePoolIsTaken(url, bytes: Data(repeating: 42, count: 10), priority: priority)
    }

    /// Real token lookup and HTTP streaming must retain the response executor through their suspension points.
    @MainActor @Test(arguments: Self.priorities)
    func aDriveRangeFinishesWhileEveryCooperativeThreadIsTaken(_ priority: TaskPriority) async throws {
        let scratch = try Scratch()
        let fixture = try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": [["id": "movie", "name": "movie.mp4", "mimeType": "video/mp4", "size": "10", "version": "1"]],
                "generatedMedia": ["movie": 10],
            ])
        let upstream = try FakeDriveServer(fixture: fixture, latencyMS: 30)
        let client = try DriveMutationTests().client(upstream, folder: scratch.path("journal"))
        let stream = try client.streamingPreview(try await client.file("movie"))
        defer { stream.stop() }
        try expectResponseWhileCooperativePoolIsTaken(stream.url, bytes: Data(repeating: 120, count: 10), priority: priority)
    }

    /// A read that has to renew the account's token first: the coalesced refresh is a task of its own, and must not
    /// wait for a cooperative thread either (W-138).
    @MainActor @Test(arguments: Self.priorities)
    func aDriveRangeRenewsItsTokenWhileEveryCooperativeThreadIsTaken(_ priority: TaskPriority) async throws {
        let scratch = try Scratch()
        let fixture = try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": [["id": "movie", "name": "movie.mp4", "mimeType": "video/mp4", "size": "10", "version": "1"]],
                "generatedMedia": ["movie": 10],
            ])
        let upstream = try FakeDriveServer(fixture: fixture, latencyMS: 30)
        let file = try await DriveMutationTests().client(upstream, folder: scratch.path("journal")).file("movie")
        // Another client of the account: no token yet, so the range read itself refreshes it.
        let reader = try DriveMutationTests().client(upstream, folder: scratch.path("reader"))
        let stream = try reader.streamingPreview(file)
        defer { stream.stop() }
        try expectResponseWhileCooperativePoolIsTaken(stream.url, bytes: Data(repeating: 120, count: 10), priority: priority)
    }

    /// Each priority has its own cooperative workers, and each one stalled a different part: dispatch creates the range
    /// Task (and so the token refresh it starts) at low priority, while URLSession's delegate calls waited for a high
    /// one (W-138).
    static let priorities: [TaskPriority] = [.low, .medium, .high]
    private static let readQueue = DispatchQueue(label: "busy-pool-read")

    @MainActor private func expectResponseWhileCooperativePoolIsTaken(_ url: URL, bytes: Data, priority: TaskPriority) throws {
        let release = Flag()
        let occupied = DispatchSemaphore(value: 0)
        let blockers =
            ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"
            ? 1 : ProcessInfo.processInfo.activeProcessorCount
        // Every worker of the priority, spinning without advertising a blocking wait.
        for _ in 0..<blockers {
            Task.detached(priority: priority) {
                occupied.signal(); while !release.isSet {}
            }
        }
        defer { release.set() }
        for _ in 0..<blockers { try #require(occupied.wait(timeout: .now() + 60) == .success) }
        let finished = DispatchSemaphore(value: 0)
        let received = OSAllocatedUnfairLock(initialState: Data())
        // The completion handler does not need a cooperative thread; neither may the server's response task.
        let request = URLSession.shared.dataTask(with: url) { data, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                received.withLock { $0 = data ?? Data() }
            }
            finished.signal()
        }
        request.resume()
        defer { request.cancel() }
        // Work that needs a held thread never ends while they are held: a long wait costs only a failing test.
        #expect(finished.wait(timeout: .now() + 60) == .success)
        #expect(received.withLock { $0 } == bytes)
    }

    /// Keeps a default-QoS GCD worker spinning per core until the returned function is called.
    private func occupyEveryCore() -> () -> Void {
        let stop = Flag()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            DispatchQueue.global().async {
                while !stop.isSet { _ = (0..<1000).reduce(0, +) }
            }
        }
        return { stop.set() }
    }

    @MainActor @Test func anIndexIsBuiltWhileEveryCoreIsBusy() async throws {
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
        #expect(await eventually { !index.status.building && index.status.updated != nil }, "\(index.status)")
        release()
        #expect(index.search("a", scope: s.path("root"))?.paths.count == 1)
    }

    @MainActor @Test func phonesArePolledWhileEveryCoreIsBusy() async throws {
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
        #expect(await eventually { m.detected.contains { $0.title == "Pixel 9" } })
    }

    /// Asking AVFoundation whether a file plays needs no free cooperative thread: synchronous work may hold them all
    /// (a preview waited 49s to start in a loaded run). Not on the main actor: the answer comes there while this test's
    /// thread, like the others, is held.
    @Test(.enabled(if: testFFmpeg != nil, "needs ffmpeg: scripts/build-ffmpeg.sh, or one on PATH"))
    func aVideoPreviewAnswersWhileEveryCooperativeThreadIsTaken() throws {
        let s = try Scratch()
        VideoPreview.testFFmpeg = testFFmpeg
        VideoPreview.testRoot = try s.folder("streams")
        defer { VideoPreview.testFFmpeg = nil; VideoPreview.testRoot = nil }
        let file = try s.file("not a video.mkv", "plain text")
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let answered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<blockers { Task.detached { hold(release) } }
        defer { for _ in 0..<blockers { release.signal() } }
        p.playableURL(for: file, owner: NSObject()) { _ in answered.signal() }
        #expect(answered.wait(timeout: .now() + 60) == .success)
    }
}

/// Holds a cooperative thread until `release` is signalled.
private func hold(_ release: DispatchSemaphore) { release.wait() }
