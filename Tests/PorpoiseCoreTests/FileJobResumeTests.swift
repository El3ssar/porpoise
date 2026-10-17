import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

/// Pausing, interrupting and resuming copies, on real files.
struct FileJobResumeTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch("jobresume") }

    func job(_ src: URL, to folder: URL) -> FileJob {
        let j = FileJob(kind: .copy, sources: [src], destinationFolder: folder)
        j.allowsClone = false  // real bytes, even on one volume
        j.publishInterval = 0  // every chunk reported
        return j
    }

    /// Waits for `signal` at most `seconds`: a job that never gets there fails its test instead of holding one of the
    /// cooperative pool's threads (3 on CI's runner) for the rest of the run.
    func wait(for signal: DispatchSemaphore, _ what: Comment, seconds: Double = 120) throws {
        try #require(signal.wait(timeout: .now() + seconds) == .success, what)
    }

    /// Runs `job` on another thread, calling `when` once with the progress where `at` first holds.
    func runInBackground(_ job: FileJob, at: @escaping (JobProgress) -> Bool, when: @escaping () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        let fired = NSLock()
        var once = false
        job.onProgress = { p in
            guard at(p) else { return }
            fired.lock()
            let first = !once
            once = true
            fired.unlock()
            if first { when() }
        }
        Thread {
            _ = try? job.run()
            done.signal()
        }.start()
        return done
    }

    /// A job that never gets where the test waits for fails that test, quickly, instead of holding a pool thread.
    @Test func aWaitThatNeverEndsFailsInsteadOfHanging() {
        let start = Date()
        withKnownIssue {
            try wait(for: DispatchSemaphore(value: 0), "never signalled", seconds: 0.2)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func interruptedThenResumedCopyIsIdentical() throws {
        let src = try scratch.randomFile("src/big.bin", size: 40 << 20)
        let dst = try scratch.folder("dst")
        let first = job(src, to: dst)
        var events: [JobEvent] = []
        let lock = NSLock()
        first.onEvent = { e in lock.withLock { events.append(e) } }
        let done = runInBackground(first, at: { $0.doneBytes > 12 << 20 }) { first.interrupt() }
        try wait(for: done, "the interrupted copy never ended")
        // Nothing at the target; a partial copy under a hidden name, reported with the good bytes.
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("big.bin").path))
        let point = try #require(
            lock.withLock { events }.compactMap { e -> ResumePoint? in
                if case .copied(_, let p) = e { return p } else { return nil }
            }.last)
        #expect(point.offset >= 12 << 20 && point.offset < 40 << 20)
        #expect(FileManager.default.fileExists(atPath: point.staging.path))
        #expect(!lock.withLock { events }.contains { if case .finished = $0 { return true } else { return false } })
        #expect(first.results.isEmpty && first.errors.isEmpty)

        // Resumed by another job: only the rest is copied, and the bytes are the same as the source's.
        let second = job(src, to: dst)
        second.resumePoints = [src: point]
        var startedAt: Int64?
        second.onProgress = { p in if startedAt == nil, p.doneBytes > 0 { startedAt = p.doneBytes } }
        _ = try second.run()
        #expect(second.errors.isEmpty)
        #expect(startedAt == point.offset)
        let copy = dst.appendingPathComponent("big.bin")
        #expect(try Data(contentsOf: copy) == Data(contentsOf: src))
        #expect(!FileManager.default.fileExists(atPath: point.staging.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["big.bin"])
        // Dates and permissions copied too.
        let a = try FileManager.default.attributesOfItem(atPath: src.path), b = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect(a[.modificationDate] as? Date == b[.modificationDate] as? Date)
        #expect(a[.posixPermissions] as? Int == b[.posixPermissions] as? Int)
    }

    @Test func aStagingFileShorterThanItsPointRestartsFromWhatIsThere() throws {
        let src = try scratch.randomFile("src/big.bin", size: 20 << 20, seed: 2)
        let dst = try scratch.folder("dst")
        // A partial copy with 3 MB written, though the journal says 9.
        let staging = dst.appendingPathComponent(".big.bin.porpoise-0000abcd")
        try Data(try Data(contentsOf: src).prefix(3 << 20)).write(to: staging)
        let j = job(src, to: dst)
        j.resumePoints = [src: ResumePoint(staging: staging, offset: 9 << 20)]
        _ = try j.run()
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
        // A point whose staging file is gone: a fresh copy.
        let k = job(src, to: try scratch.folder("dst2"))
        k.resumePoints = [src: ResumePoint(staging: staging, offset: 5)]
        _ = try k.run()
        #expect(try Data(contentsOf: scratch.path("dst2/big.bin")) == Data(contentsOf: src))
    }

    @Test func pauseHoldsTheCopyAndResumeFinishesIt() throws {
        let src = try scratch.randomFile("src/big.bin", size: 32 << 20, seed: 3)
        let dst = try scratch.folder("dst")
        let j = job(src, to: dst)
        var latest: Int64 = 0
        let lock = NSLock()
        let paused = DispatchSemaphore(value: 0)
        let done = runInBackground(
            j,
            at: { p in
                lock.withLock { latest = p.doneBytes }
                return p.doneBytes > 8 << 20
            }
        ) {
            j.pause()
            paused.signal()
        }
        try wait(for: paused, "the copy never got to the pause")
        Thread.sleep(forTimeInterval: 0.3)
        let held = lock.withLock { latest }
        Thread.sleep(forTimeInterval: 0.4)
        #expect(lock.withLock { latest } == held)  // nothing copied while paused
        #expect(j.isPaused)
        #expect(held < 32 << 20)
        j.resume()
        try wait(for: done, "the resumed copy never ended")
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
    }

    @Test func pausedThenCancelledLeavesNothing() async throws {
        let src = try scratch.randomFile("src/big.bin", size: 24 << 20, seed: 4)
        let dst = try scratch.folder("dst")
        let j = job(src, to: dst)
        let (paused, progress) = AsyncStream<Void>.makeStream()
        j.onProgress = { p in
            if p.doneBytes > 4 << 20 && !j.isPaused {
                j.pause()
                progress.yield(())
                progress.finish()
            }
        }
        defer { j.cancel() }
        // A synchronous copy must not occupy a cooperative worker while its controller needs one.
        let work = Task {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                Thread {
                    do { _ = try j.run(); done.resume() } catch { done.resume(throwing: error) }
                    progress.finish()
                }.start()
            }
        }
        var events = paused.makeAsyncIterator()
        try #require(await events.next() != nil)
        #expect(j.isPaused)
        // Cancel only once the copy has actually paused, without depending on a global-queue timer.
        j.cancel()
        try await work.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
    }

    @Test func stoppedQueueResumesWithoutRecopyingFinishedItems() throws {
        let first = try scratch.file("src/first", "finished")
        let big = try scratch.randomFile("src/big", size: 24 << 20)
        let destination = try scratch.folder("dst")
        let job = FileJob(kind: .copy, sources: [first, big], destinationFolder: destination)
        job.allowsClone = false
        job.chunkDelay = 0.05
        job.onProgress = { p in if p.currentName == "big", p.doneBytes > 4 << 20 { job.cancel() } }
        _ = try job.run()
        let copied = destination.appendingPathComponent("first")
        let inode = try FileManager.default.attributesOfItem(atPath: copied.path)[.systemFileNumber] as? NSNumber
        #expect(job.remainingSources == [big])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["first"])
        let resumed = FileJob(kind: .copy, sources: job.remainingSources, destinationFolder: destination)
        _ = try resumed.run()
        #expect(try FileManager.default.attributesOfItem(atPath: copied.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try Data(contentsOf: destination.appendingPathComponent("big")) == Data(contentsOf: big))
    }

    @Test func stoppedMergeKeepsItsAlreadyPublishedLeavesOnResume() throws {
        let first = try scratch.file("src/folder/a.txt", "finished")
        _ = try scratch.randomFile("src/folder/z.bin", size: 24 << 20)
        let destination = try scratch.folder("dst")
        try scratch.folder("dst/folder")
        let job = FileJob(kind: .copy, sources: [first.deletingLastPathComponent()], destinationFolder: destination)
        job.conflictRule = .replace; job.allowsClone = false; job.chunkDelay = 0.05
        job.onProgress = { p in if p.doneBytes > 4 << 20 { job.cancel() } }
        _ = try job.run()
        let copied = scratch.path("dst/folder/a.txt")
        let inode = try FileManager.default.attributesOfItem(atPath: copied.path)[.systemFileNumber] as? NSNumber
        #expect(
            job.isCancelled
                && job.completedTransfers.contains {
                    $0.key.resolvingSymlinksInPath() == first.resolvingSymlinksInPath()
                        && $0.value.resolvingSymlinksInPath() == copied.resolvingSymlinksInPath()
                })
        let resumed = FileJob(kind: .copy, sources: job.remainingSources, destinationFolder: destination)
        resumed.conflictRule = .replace; resumed.completedTransfers = job.completedTransfers
        _ = try resumed.run()
        #expect(try FileManager.default.attributesOfItem(atPath: copied.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try Data(contentsOf: scratch.path("src/folder/z.bin")) == Data(contentsOf: scratch.path("dst/folder/z.bin")))
    }

    @Test func fastCopiesDoNotFloodIncomingItemNotifications() throws {
        let files = try (0..<500).map { try scratch.file("src/file-\($0)", "tiny") }
        let job = FileJob(kind: .copy, sources: files, destinationFolder: try scratch.folder("dst"))
        var events = 0
        job.onIncoming = { _, _ in events += 1 }
        let started = ProcessInfo.processInfo.systemUptime
        _ = try job.run()
        let seconds = ProcessInfo.processInfo.systemUptime - started
        #expect(job.errors.isEmpty)
        #expect(events <= 2 + 8 * Int(ceil(seconds)))
    }

    @Test func slowIncomingItemUsesItsLogicalTargetAndByteBaseline() throws {
        let first = try scratch.file("src/first", "x")
        let large = try scratch.randomFile("src/large", size: 32 << 20)
        let destination = try scratch.folder("dst")
        let job = FileJob(kind: .copy, sources: [first, large], destinationFolder: destination)
        job.allowsClone = false; job.chunkDelay = 0.1
        var events: [(FileItem?, Int64)] = []
        job.onIncoming = { events.append(($0, $1)) }
        _ = try job.run()
        let showing = events.compactMap { $0.0 }
        #expect(showing.map(\.url) == [destination.appendingPathComponent("large")])
        #expect(showing.first?.size == 32 << 20)
        #expect(events.first?.1 == 1)
        #expect(events.last?.0 == nil && events.count == 2)
    }

    @Test func eventsForEachItem() throws {
        let a = try scratch.file("src/a.txt", "a")
        let b = try scratch.file("src/b.txt", "b")
        let dst = try scratch.folder("dst")
        try scratch.file("dst/b.txt", "existing")
        let j = FileJob(kind: .copy, sources: [a, b], destinationFolder: dst)
        j.resolveConflict = { _ in ConflictAnswer(.skip) }
        var events: [JobEvent] = []
        j.onEvent = { events.append($0) }
        _ = try j.run()
        #expect(events.count == 4)
        guard case .started(0, let staging?) = events[0] else { Issue.record("\(events)"); return }
        #expect(staging.lastPathComponent.hasPrefix(".a.txt.porpoise-"))
        #expect(events[1] == .placed(index: 0, target: dst.appendingPathComponent("a.txt")))
        #expect(events[2] == .finished(index: 0, outcome: .done))
        #expect(events[3] == .finished(index: 1, outcome: .skipped))
        // A failure is listed for Retry.
        let missing = scratch.path("src/missing.txt")
        let k = FileJob(kind: .copy, sources: [missing], destinationFolder: dst)
        var last: JobEvent?
        k.onEvent = { last = $0 }
        _ = try k.run()
        #expect(k.failedSources == [missing])
        #expect(last == .finished(index: 0, outcome: .failed))
    }

    @Test func largeFilesCloneOnOneVolume() throws {
        let src = try scratch.randomFile("src/big.bin", size: 16 << 20, seed: 5)
        let dst = try scratch.folder("dst")
        let j = FileJob(kind: .copy, sources: [src], destinationFolder: dst)
        _ = try j.run()
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
    }
}
