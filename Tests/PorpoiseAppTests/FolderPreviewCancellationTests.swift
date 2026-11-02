import AppKit
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor struct FolderPreviewCancellationTests {
    @Test func alphabeticalCandidateDiscoveryStopsWhenCancelled() throws {
        let scratch = try Scratch()
        for index in 0..<100 { try scratch.file("file\(index).txt") }
        let names = Thumbnails.firstNames(in: scratch.url, count: 3)
        #expect(names == ["file0.txt", "file1.txt", "file2.txt"])
        var checks = 0
        let cancelled = Thumbnails.firstNames(
            in: scratch.url, count: 80,
            cancelled: {
                checks += 1
                return checks > 4
            })
        #expect(cancelled.isEmpty && checks <= 6)
        #expect(Thumbnails.firstNames(in: scratch.url, count: 0).isEmpty)
    }

    @Test func generationResetDropsQueuedDiscoveryAndCancelsTheRunningLane() {
        var limits = ThumbnailWorkScheduler.Limits()
        limits.active[.folder] = 1
        let scheduler = ThumbnailWorkScheduler(limits: limits)
        let url = URL(fileURLWithPath: "/fixture")
        var running: ThumbnailWorkScheduler.Job?
        var cancelled = false, dropped = false, secondStarted = false
        scheduler.submit(
            "folder-candidates|old|one", lane: .folder, interest: .init(owner: nil, url: url),
            body: { job in
                running = job; job.onCancel { cancelled = true }
            }, dropped: {})
        scheduler.submit(
            "folder-candidates|old|two", lane: .folder, interest: .init(owner: nil, url: url),
            body: { _ in
                secondStarted = true
            }, dropped: { dropped = true })
        scheduler.cancel(keysWithPrefix: "folder-candidates|")
        #expect(cancelled && dropped && !secondStarted)
        #expect(scheduler.pendingCount == 0 && scheduler.runningCount(.folder) == 1)
        running?.finish()
        #expect(scheduler.runningCount(.folder) == 0)
    }
}
