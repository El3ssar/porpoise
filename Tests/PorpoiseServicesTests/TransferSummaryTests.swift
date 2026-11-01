import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

struct TransferSummaryTests {
    @Test func creditsArrivingBeforeTheFirstProgressSnapshotAreRetained() {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.progress = nil
        activity.creditProgress(bytes: 40)
        #expect(activity.progress?.nonTransferredBytes == 40)
        var first = activity.progress!
        first.totalBytes = 100; first.doneBytes = 40
        activity.state = .running
        activity.updateProgress(first, at: 0)
        first.doneBytes = 100
        activity.updateProgress(first, at: 1)
        #expect(activity.progress?.transferredBytes == 60)
        #expect(activity.rate.bytesPerSecond == 60)
    }

    @Test func skippedAndReusedBytesNeverSpikeThroughputOrHistory() throws {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running
        var progress = JobProgress(
            kind: .copy, totalBytes: 1_000_004_000, doneBytes: 0, totalItems: 2, doneItems: 0, currentName: "real", destination: nil)
        activity.updateProgress(progress, at: 0)
        progress.doneBytes = 1000
        activity.updateProgress(progress, at: 1)
        progress.doneBytes += 1_000_000_000
        progress.nonTransferredBytes = 1_000_000_000
        activity.updateProgress(progress, at: 1.01)
        progress.doneBytes += 1000
        activity.updateProgress(progress, at: 2)
        #expect(progress.transferredBytes == 2000 && progress.transferBytesTotal == 4000)
        #expect(activity.rate.bytesPerSecond == 1000)
        #expect(activity.transferSummary.speedSamples.map(\.bytesPerSecond) == [1000, 1000])
        #expect(activity.transferSummary.doneBytes == 1_000_002_000)
    }

    @Test func snapshotPreservesUnknownCountsAndFreezesFinishedElapsedTime() {
        let activity = Activity(kind: .copy, sources: [URL(fileURLWithPath: "/fixture/a")], destination: nil, job: nil)
        let start = Date(timeIntervalSince1970: 100)
        activity.startedAt = start
        activity.state = .running
        activity.progress?.currentName = "a"
        activity.progress?.totalFiles = 8
        activity.progress?.doneFiles = 3
        activity.progress?.totalFolders = 2
        activity.progress?.doneFolders = 1
        #expect(activity.transferSummary(at: start.addingTimeInterval(10)).totalFiles == nil)
        activity.progress?.countsAreComplete = true
        let running = activity.transferSummary(at: start.addingTimeInterval(10))
        #expect(running.currentName == "a" && running.elapsed == 10)
        #expect(running.completedFiles == 3 && running.totalFiles == 8)
        #expect(running.completedFolders == 1 && running.totalFolders == 2)
        activity.finishedAt = start.addingTimeInterval(12)
        activity.state = .completed
        let ended = activity.transferSummary(at: start.addingTimeInterval(100))
        #expect(ended.elapsed == 12 && ended.timeLeftText == nil && ended.speedText == nil)
    }

    @Test func pauseAndWaitingHideStaleSpeedAndSeparateGraphSegments() {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running
        activity.speedHistory.add(bytes: 0, at: 0)
        activity.speedHistory.add(bytes: 1000, at: 1)
        activity.rate.add(bytes: 0, at: 0)
        activity.rate.add(bytes: 1000, at: 1)
        #expect(activity.transferSummary.bytesPerSecond == 1000)
        activity.state = .paused
        #expect(activity.transferSummary.bytesPerSecond == nil && activity.transferSummary.timeLeftText == nil)
        activity.state = .running
        activity.speedHistory.add(bytes: 1000, at: 100)
        activity.speedHistory.add(bytes: 2000, at: 101)
        #expect(activity.transferSummary.speedSamples.map(\.bytesPerSecond) == [1000, 1000])
        #expect(activity.transferSummary.speedSamples[0].segment != activity.transferSummary.speedSamples[1].segment)
        activity.notice = "Waiting for network"
        #expect(activity.transferSummary.speedText == nil && activity.transferSummary.timeLeftText == nil)
    }
}
