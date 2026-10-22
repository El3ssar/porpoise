import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem
@testable import PorpoiseServices

/// The Activity window's jobs: queue and concurrency, pause, retry, verification, history, and resuming after a
/// relaunch, with real files.
@MainActor @Suite(.isolatedSettings, .serialized)
struct ActivityTests {
    let s: Scratch
    let ui = ScriptedUI()
    let c: FileOperationsController

    init() throws {
        s = try Scratch("activity")
        c = makeController(ui)
        c.journals = JournalStore(folder: s.path("journals"))
        // Its own: Drive transfers of tests running meanwhile record theirs in the shared one, and would be plans here.
        c.driveJournals = DriveMutationJournal(folder: s.path("drive-journals"))
        c.history = OperationHistory(file: s.path("history.jsonl"))
        // Real byte copies, slow enough to be caught in the middle.
        c.prepareJob = { job in
            job.allowsClone = false
            job.chunkDelay = 0.03
            // Every chunk reported: a 32 MB copy takes about 240 ms, less than the usual interval between reports.
            job.publishInterval = 0
        }
    }

    // MARK: Resuming after a relaunch

    @Test func interruptedCopyResumesAfterRelaunchWithIdenticalBytes() async throws {
        let src = try s.randomFile("src/big.bin", size: 48 << 20)
        let small = try s.file("src/small.txt", "small")
        let dst = try s.folder("dst")
        onWorkerProgress(item: 1) { job, progress in if progress.doneBytes > 16 << 20 { job.pause() } }
        c.run(.copy, [small, src], to: dst, window: nil)
        let a = try #require(c.activities.last)
        #expect(await poll { (a.progress?.doneBytes ?? 0) > 16 << 20 })
        // Quitting: the job stops where it is.
        c.interruptAll()
        #expect(await poll { a.state == .interrupted })
        #expect(c.journals.all().count == 1)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("small.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("big.bin").path))

        // Next launch: a new controller finds the journal.
        let next = makeController(ScriptedUI())
        next.journals = c.journals
        next.driveJournals = c.driveJournals
        next.history = c.history
        let plans = next.recoveryPlans()
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.sources == [src])  // the small file was done
        let point = try #require(plan.resumePoints[src])
        #expect(point.offset > 0)
        #expect(plan.summary.hasPrefix("Copying to “dst” was interrupted: 1 item is left ("))
        var finished = false
        next.recover(plan, window: nil) { _ in finished = true }
        #expect(await poll { finished })
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).sorted() == ["big.bin", "small.txt"])
        #expect(next.journals.all().isEmpty)
        #expect(next.recoveryPlans().isEmpty)
        #expect(c.history.entries().map(\.outcome).contains("Interrupted"))
    }

    @Test func changesMadeMeanwhileAreDetected() async throws {
        let src = try s.randomFile("src/big.bin", size: 32 << 20, seed: 2)
        let dst = try s.folder("dst")
        onWorkerProgress(item: 0) { job, progress in if progress.doneBytes > 8 << 20 { job.pause() } }
        c.run(.copy, [src], to: dst, window: nil)
        let a = try #require(c.activities.last)
        #expect(await poll { (a.progress?.doneBytes ?? 0) > 8 << 20 })
        c.interruptAll()
        #expect(await poll { a.state == .interrupted })
        var plan = try #require(c.recoveryPlans().first)
        let staging = try #require(plan.resumePoints[src]?.staging)

        // Someone else's file now sits where the partial copy was: kept, and the copy starts over.
        try FileManager.default.removeItem(at: staging)
        try Data("not ours".utf8).write(to: staging)
        plan = try #require(c.recoveryPlans().first)
        #expect(plan.resumePoints.isEmpty && plan.sources == [src])
        #expect(plan.notes.first?.hasPrefix("The partial copy of “big.bin” was changed meanwhile") == true)
        var finished = false
        c.recover(plan, window: nil) { _ in finished = true }
        #expect(await poll { finished })
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
        #expect(try String(contentsOf: staging, encoding: .utf8) == "not ours")
    }

    @Test func aChangedSourceStartsOverAndAGoneDestinationIsReported() throws {
        let src = try s.file("src/a.txt", "a")
        let dst = try s.folder("dst")
        let staging = try s.file("dst/.a.txt.porpoise-00001111", "partial")
        var j = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        j.apply(.started(index: 0, staging: staging))
        j.apply(.copied(index: 0, point: ResumePoint(staging: staging, offset: 3)))
        try "changed".write(to: src, atomically: false, encoding: .utf8)
        let plan = try #require(FileOperationsController.plan(j))
        #expect(plan.resumePoints.isEmpty && plan.partials == [staging])
        #expect(plan.notes == ["“a.txt” changed since: it's copied again from the start."])
        c.discard(plan)
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        var gone = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: s.path("nowhere"))
        gone.items[0].state = .pending
        let p2 = try #require(FileOperationsController.plan(gone))
        #expect(p2.isEmpty && p2.notes == ["The destination “nowhere” is no longer there."])
    }

    @Test func deletionsAreNeverRepeatedSilently() throws {
        let a = try s.file("trash/a.txt", "a")
        let b = s.path("trash/b.txt")  // already deleted when the job stopped
        var j = JobJournal(id: UUID(), kind: .delete, sources: [b, a], destination: nil)
        j.apply(.finished(index: 0, outcome: .done))
        let plan = try #require(FileOperationsController.plan(j))
        #expect(plan.isDestructive)
        #expect(plan.sources == [a])
        #expect(plan.summary == "Deleting was interrupted: 1 item is left.")
    }

    @Test func anInterruptedMoveFinishesOnlyWithAnIdenticalCopy() async throws {
        let src = try s.file("src/m.txt", "move me")
        let dst = try s.folder("dst")
        try FileManager.default.copyItem(at: src, to: dst.appendingPathComponent("m.txt"))
        var j = JobJournal(id: UUID(), kind: .move, sources: [src], destination: dst)
        j.apply(.placed(index: 0, target: dst.appendingPathComponent("m.txt")))
        c.journals.save(j)
        let plan = try #require(c.recoveryPlans().first)
        #expect(plan.unfinishedMoves.map(\.source) == [src])
        c.recover(plan, window: nil)
        // Checked off the main thread, as an activity of its own.
        #expect(await poll { !FileManager.default.fileExists(atPath: src.path) })
        #expect(await poll { c.journals.all().isEmpty })
        // A copy that differs: the original stays.
        let src2 = try s.file("src/n.txt", "original")
        try s.file("dst/n.txt", "different")
        var k = JobJournal(id: UUID(), kind: .move, sources: [src2], destination: dst)
        k.apply(.placed(index: 0, target: dst.appendingPathComponent("n.txt")))
        let plan2 = try #require(FileOperationsController.plan(k))
        c.recover(plan2, window: nil)
        #expect(await poll { ui.errors.last?.hasPrefix("“n.txt” wasn't removed") == true })
        #expect(FileManager.default.fileExists(atPath: src2.path))
    }

    @Test func journalsOfOtherVersionsAreLeftAlone() throws {
        try FileManager.default.createDirectory(at: s.path("journals"), withIntermediateDirectories: true)
        try Data(#"{"version": 99}"#.utf8).write(to: s.path("journals/x.json"))
        try Data("garbage".utf8).write(to: s.path("journals/y.json"))
        #expect(c.journals.all().isEmpty)
    }

    /// A journal is begun without the caller waiting for its sources to be looked at or the file written; what follows
    /// (the job's checkpoints, its removal, a read) still comes after it.
    @Test func journalsAreWrittenOffTheCallersThreadInOrder() throws {
        let store = JournalStore(folder: s.path("ordered-journals"))
        let source = try s.file("ordered/a.txt", "a")
        let target = s.path("ordered-out/a.txt")
        let id = UUID(), gone = UUID()
        // Many sources: looking at them goes on until the caller has gone on, which it can only do if it didn't wait.
        let callerWentOn = DispatchSemaphore(value: 0), didNotWait = Flag()
        store.begin {
            if callerWentOn.wait(timeout: .now() + 30) == .success { didNotWait.set() }
            return JobJournal(id: id, kind: .copy, sources: [source], destination: target.deletingLastPathComponent())
        }
        callerWentOn.signal()
        store.record(.placed(index: 0, target: target), id: id)  // as the job's worker does, right away
        #expect(didNotWait.isSet)
        store.begin { JobJournal(id: gone, kind: .copy, sources: [source], destination: nil) }
        store.remove(gone)  // a queued job cancelled before it was written
        let journals = store.all()
        #expect(journals.map(\.id) == [id])
        #expect(journals.first?.items.first?.state == .placed)
        store.remove(id)
        store.flush()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: s.path("ordered-journals").path)) ?? []).isEmpty)
    }

    // MARK: Queue, pause, retry

    @Test func copiesQueueBehindTheConcurrencyLimit() async throws {
        c.concurrency = 1
        let one = try s.randomFile("src/one.bin", size: 24 << 20, seed: 3)
        let two = try s.randomFile("src/two.bin", size: 12 << 20, seed: 4)
        let three = try s.file("src/three.txt", "3")
        let dst = try s.folder("dst")
        c.run(.copy, [one], to: dst, window: nil)
        c.run(.copy, [two], to: dst, window: nil)
        c.run(.copy, [three], to: dst, window: nil)
        let (a, b, d) = (c.activities[0], c.activities[1], c.activities[2])
        #expect(a.state == .running && b.state == .queued && d.state == .queued)
        #expect(b.statusText == "Waiting for other operations to finish")
        // The last one moves up; the middle one is cancelled before it starts.
        c.move(d, by: -1)
        #expect(c.activities.map(\.id) == [a.id, d.id, b.id])
        c.cancel(b)
        #expect(!c.activities.contains { $0 === b })
        #expect(await poll { d.state == .completed })
        #expect(a.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("two.bin").path))
        #expect(c.journals.all().isEmpty)
        // Trashing doesn't wait behind copies.
        c.run(.copy, [one], to: try s.folder("dst2"), window: nil)
        c.run(.delete, [try s.file("junk.txt", "")], window: nil)
        #expect(c.activities.last?.state == .running)
        #expect(await poll { c.activities.allSatisfy(\.state.isEnded) })
        c.clearEnded()
        #expect(c.activities.isEmpty)
    }

    @Test func pauseAndResumeThroughTheController() async throws {
        let src = try s.randomFile("src/p.bin", size: 32 << 20, seed: 5)
        let dst = try s.folder("dst")
        // The worker waits past 4 MB until the controller has paused it, so the copy can't finish first.
        let pausedByController = DispatchSemaphore(value: 0), held = Flag()
        onWorkerProgress(item: 0) { _, progress in
            guard progress.doneBytes > 4 << 20, !held.isSet else { return }
            held.set(); _ = pausedByController.wait(timeout: .now() + 60)
        }
        c.run(.copy, [src], to: dst, window: nil)
        let a = try #require(c.activities.last)
        #expect(await poll { (a.progress?.doneBytes ?? 0) > 4 << 20 })
        #expect(a.canPause && a.pauseUnavailable == nil)
        c.pause(a)
        pausedByController.signal()
        #expect(a.state == .paused && a.statusText.hasPrefix("Paused — "))
        // The job holds: paused, and still paused a moment later.
        #expect(await poll { a.job?.isPaused == true })
        await expectStays(for: 0.3) { a.job?.isPaused == true }
        c.resume(a)
        #expect(a.state == .running)
        #expect(await poll { a.state == .completed })
        #expect(try Data(contentsOf: dst.appendingPathComponent("p.bin")) == Data(contentsOf: src))
    }

    @Test func quittingDoesNotStartTheNextQueuedCopy() async throws {
        c.concurrency = 1
        let big = try s.randomFile("src/shutdown.bin", size: 32 << 20)
        let waiting = try s.file("src/waiting.txt", "leave queued")
        let dst = try s.folder("dst")
        onWorkerProgress(item: 0) { job, progress in if progress.doneBytes > 0 { job.pause() } }
        c.run(.copy, [big], to: dst, window: nil)
        c.run(.copy, [waiting], to: dst, window: nil)
        let first = c.activities[0], second = c.activities[1]
        #expect(await poll { (first.progress?.doneBytes ?? 0) > 0 })
        c.interruptAll()
        #expect(await poll { first.state == .interrupted })
        #expect(second.state == .queued)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("waiting.txt").path))
        #expect(c.journals.all().count == 2)
    }

    @Test func retryRunsTheFailedItemsAgain() async throws {
        let ok = try s.file("src/ok.txt", "ok")
        let missing = s.path("src/later.txt")
        let dst = try s.folder("dst")
        c.run(.copy, [ok, missing], to: dst, window: nil)
        let a = try #require(c.activities.last)
        #expect(await poll { a.state.isEnded })
        #expect(a.state == .completed && a.failedSources == [missing] && a.errors.count == 1)
        #expect(a.statusText == "Done, with 1 error")
        try s.file("src/later.txt", "now here")
        c.retry(a, window: nil)
        let b = try #require(c.activities.last)
        #expect(b.sources == [missing])
        #expect(await poll { b.state == .completed })
        #expect(try String(contentsOf: dst.appendingPathComponent("later.txt"), encoding: .utf8) == "now here")
    }

    @Test func copiesAreVerifiedWhenAsked() async throws {
        Settings.shared.verifyCopies = true
        try s.file("src/folder/a.txt", "a")
        try s.file("src/folder/b.txt", "bb")
        let file = try s.file("src/c.txt", "ccc")
        let dst = try s.folder("dst")
        c.run(.copy, [s.path("src/folder"), file], to: dst, window: nil)
        let a = try #require(c.activities.last)
        #expect(await poll { a.state == .completed && a.verification != nil })
        let v = try #require(a.verification)
        #expect(v.ok && v.files == 3 && v.bytes == 6)
        #expect(a.statusText == "Done. Verified 3 files (6 B): identical to the originals.")
        #expect(c.history.entries().first?.verification == v.summary)
    }

    @Test func cancellingVerificationDoesNotReportAPartialResultAsVerified() async throws {
        Settings.shared.verifyCopies = true
        let source = try s.file("source", size: 8 << 20), target = try s.file("target", size: 8 << 20)
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: s.url)
        job.control.finish()
        let activity = Activity(kind: .copy, sources: [source], destination: s.url, job: job)
        activity.placed = [0: target]
        c.ended(activity, errors: [])
        #expect(activity.state == .verifying)
        c.cancel(activity)
        #expect(await poll { activity.state == .cancelled })
        #expect(activity.verification == nil)
        c.resume(activity)
        #expect(await poll { activity.state == .completed && activity.verification != nil })
        #expect(activity.verification?.ok == true)
    }

    // MARK: History

    @Test func historyIsSearchableAndExportable() async throws {
        let f = try s.file("src/report, final.txt", "x")
        let dst = try s.folder("Backup")
        c.run(.copy, [f], to: dst, window: nil)
        #expect(await poll { c.history.entries().count == 1 })
        let e = try #require(c.history.entries().first)
        #expect(e.operation == "Copying" && e.outcome == "Completed" && e.items == 1 && e.destination == dst.path)
        #expect(c.history.entries(matching: "backup copying").count == 1)
        #expect(c.history.entries(matching: "nothing-like-this").isEmpty)
        let csv = OperationHistory.csv(c.history.entries())
        #expect(csv.hasPrefix("Date,Operation,Items,Sources,Destination,Bytes,Seconds,Outcome,Errors,Verification\r\n"))
        #expect(csv.contains("\"\(f.path)\""))  // a comma in the name: quoted
        // Read back by another instance; cleared.
        let again = OperationHistory(file: s.path("history.jsonl"))
        #expect(again.entries().count == 1)
        again.clear()
        #expect(again.entries().isEmpty)
    }

    /// Runs `body` on the worker with each progress report of top-level item `index` of the next job started, to hold
    /// the copy at an observable byte boundary (pause it, or wait for the test). A loaded main queue can otherwise
    /// receive the first progress callback only after a short copy has already finished. Jobs started after it (a
    /// recovery, a retry) run freely.
    private func onWorkerProgress(item index: Int, _ body: @escaping (FileJob, JobProgress) -> Void) {
        ui.onJobStarted = { [ui] job in
            ui.onJobStarted = nil
            let record = job.onEvent
            job.onEvent = { [weak job] event in
                record(event)
                guard case .started(index: index, staging: _) = event, let job else { return }
                let report = job.onProgress
                job.onProgress = { [weak job] progress in
                    report(progress)
                    if let job { body(job, progress) }
                }
            }
        }
    }

    @Test func historyNeverHoldsPasswords() {
        #expect(OperationHistory.describe(URL(string: "sftp://me:s3cret@host:22/home/me/file?token=abc#x")!) == "sftp://host:22/home/me/file")
        #expect(OperationHistory.describe(URL(fileURLWithPath: "/tmp/a b")) == "/tmp/a b")
    }
}
