import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct RemoteTransferProgressCountsTests {
    @Test func sameJobRetryPreservesTransferredBytesButPriorSessionResumeDoesNotCountThem() throws {
        func job() -> RemoteTransferJob {
            let value = RemoteTransferJob(
                kind: .copy, sources: [], destination: nil, control: JobControl(policy: TransferPolicy(retries: 1, backoff: 0.01)), rule: .ask,
                options: .init())
            value.progress.totalBytes = 100
            value.activeLimit = 100
            return value
        }
        let retried = job()
        var attempt = 0
        try retried.retryDownload {
            attempt += 1
            if attempt == 1 {
                retried.advance(bytes: 40)
                throw TransferConnectionError(message: "Connection lost")
            }
            retried.creditActive(bytes: 40)
            retried.advance(bytes: 40)
            retried.advance(bytes: 60)
        }
        #expect(attempt == 2)
        #expect(retried.progress.doneBytes == 100 && retried.progress.transferredBytes == 100)
        #expect(retried.progress.transferBytesTotal == 100)
        let resumed = job()
        try resumed.retryDownload {
            resumed.creditActive(bytes: 40)
            resumed.advance(bytes: 40)
            resumed.advance(bytes: 60)
        }
        #expect(resumed.progress.doneBytes == 100 && resumed.progress.transferredBytes == 60)
        #expect(resumed.progress.transferBytesTotal == 60)
    }

    @Test func keptDownloadLegIsCreditedWithoutCountingItAgainAsNewNetworkBytes() {
        let job = RemoteTransferJob(kind: .copy, sources: [], destination: nil, control: JobControl(), rule: .ask, options: .init())
        job.progress.totalBytes = 100; job.activeLimit = 100; job.activeLegs = 2
        job.creditActive(bytes: 100, reportedByProgress: false)
        job.advance(bytes: 100)
        #expect(job.progress.doneBytes == 100 && job.progress.nonTransferredBytes == 50)
        #expect(job.progress.transferredBytes == 50)
        let fallback = RemoteTransferJob(kind: .copy, sources: [], destination: nil, control: JobControl(), rule: .ask, options: .init())
        fallback.progress.totalBytes = 100; fallback.activeLimit = 100
        fallback.creditActive(bytes: 100)
        fallback.resetActiveCredits()
        fallback.advance(bytes: 100)
        #expect(fallback.progress.transferredBytes == 100 && fallback.progress.nonTransferredBytes == 0)
    }

    @Test(.isolatedSettings) func skippedMergedAndReusedFoldersDoNotDoubleCount() throws {
        for mode in ["skip", "merge", "reuse"] {
            let scratch = try Scratch()
            let nested = try scratch.folder("source/nested/empty")
            let source = nested.deletingLastPathComponent().deletingLastPathComponent()
            try scratch.file("source/nested/a.txt", "new")
            try scratch.file("source/b.txt", "b")
            let destination = try scratch.folder("destination")
            try scratch.file("destination/source/nested/a.txt", "old")
            let target = destination.appendingPathComponent("source")
            let job = RemoteTransferJob(
                kind: .copy, sources: [source], destination: destination, control: JobControl(), rule: .ask,
                options: TransferCompareOptions(), completed: mode == "reuse" ? [source: target] : [:])
            job.resolve = { info in .init(mode == "merge" && info.source.isDirectory ? .writeInto : .skip) }
            job.run()
            #expect(job.errors.isEmpty && job.progress.countsAreComplete)
            #expect(job.progress.doneFiles == 2 && job.progress.totalFiles == 2)
            #expect(job.progress.doneFolders == 3 && job.progress.totalFolders == 3)
            if mode != "merge" {
                #expect(job.progress.nonTransferredBytes == 4 && job.progress.transferredBytes == 0)
            } else {
                // The new leaf may be cloned by the local transport; at least the skipped leaf is credited.
                #expect(job.progress.nonTransferredBytes >= 3)
            }
            #expect(try String(contentsOf: target.appendingPathComponent("nested/a.txt"), encoding: .utf8) == "old")
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("b.txt").path) == (mode == "merge"))
        }
    }

    /// Exercise the remote worker's recursive accounting with local transport, without an account or network.
    @Test(.isolatedSettings) func nestedWorkerTransferCountsCompletedFoldersOnce() throws {
        let scratch = try Scratch()
        let source = try scratch.folder("source/nested/empty")
        try scratch.file("source/nested/a.txt", "a")
        try scratch.file("source/b.txt", "bb")
        let destination = try scratch.folder("destination")
        let job = RemoteTransferJob(
            kind: .copy, sources: [source.deletingLastPathComponent().deletingLastPathComponent()], destination: destination,
            control: JobControl(), rule: .ask, options: TransferCompareOptions())
        job.run()
        #expect(job.errors.isEmpty)
        #expect(job.progress.countsAreComplete)
        #expect(job.progress.doneFiles == 2 && job.progress.totalFiles == 2)
        #expect(job.progress.doneFolders == 3 && job.progress.totalFolders == 3)
    }
}
