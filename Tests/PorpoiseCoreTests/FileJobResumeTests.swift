import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

/// Pausing, interrupting and resuming copies, on real files.
struct FileJobResumeTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch("jobresume") }

    /// A file of `size` pseudo-random bytes (different for each seed).
    func randomFile(_ name: String, size: Int, seed: UInt64 = 1) throws -> URL {
        var g = SeededGenerator(seed: seed)
        var d = Data(count: size)
        d.withUnsafeMutableBytes { b in
            let words = b.bindMemory(to: UInt64.self)
            for i in 0..<words.count { words[i] = g.next() }
        }
        let u = scratch.path(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: u)
        return u
    }

    func job(_ src: URL, to folder: URL) -> FileJob {
        let j = FileJob(kind: .copy, sources: [src], destinationFolder: folder)
        j.allowsClone = false  // real bytes, even on one volume
        j.publishInterval = 0  // every chunk reported
        return j
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

    @Test func interruptedThenResumedCopyIsIdentical() throws {
        let src = try randomFile("src/big.bin", size: 40 << 20)
        let dst = try scratch.folder("dst")
        let first = job(src, to: dst)
        var events: [JobEvent] = []
        let lock = NSLock()
        first.onEvent = { e in lock.withLock { events.append(e) } }
        let done = runInBackground(first, at: { $0.doneBytes > 12 << 20 }) { first.interrupt() }
        done.wait()
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
        let src = try randomFile("src/big.bin", size: 20 << 20, seed: 2)
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
        let src = try randomFile("src/big.bin", size: 32 << 20, seed: 3)
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
        paused.wait()
        Thread.sleep(forTimeInterval: 0.3)
        let held = lock.withLock { latest }
        Thread.sleep(forTimeInterval: 0.4)
        #expect(lock.withLock { latest } == held)  // nothing copied while paused
        #expect(j.isPaused)
        #expect(held < 32 << 20)
        j.resume()
        done.wait()
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
    }

    @Test func pausedThenCancelledLeavesNothing() throws {
        let src = try randomFile("src/big.bin", size: 24 << 20, seed: 4)
        let dst = try scratch.folder("dst")
        let j = job(src, to: dst)
        let done = runInBackground(j, at: { $0.doneBytes > 4 << 20 }) {
            j.pause()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { j.cancel() }
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
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
        let src = try randomFile("src/big.bin", size: 16 << 20, seed: 5)
        let dst = try scratch.folder("dst")
        let j = FileJob(kind: .copy, sources: [src], destinationFolder: dst)
        _ = try j.run()
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
    }
}
