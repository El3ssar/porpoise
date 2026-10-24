import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem
@testable import PorpoiseServices

/// Resuming an interrupted local job after a relaunch must never publish bytes the source doesn't have, delete or
/// remove an item that isn't the one the job worked on, or lose its record of the work before the next attempt has one.
@MainActor @Suite(.isolatedSettings, .serialized)
struct RecoveryIntegritySafetyTests {
    let s: Scratch
    let ui = ScriptedUI()
    let c: FileOperationsController

    init() throws {
        s = try Scratch("recovery-integrity")
        c = makeController(ui)
        c.journals = JournalStore(folder: s.path("journals"))
        c.driveJournals = DriveMutationJournal(folder: s.path("drive-journals"))
        c.history = OperationHistory(file: s.path("history.jsonl"))
        c.prepareJob = { job in job.allowsClone = false }
    }

    struct WriteFailure: Error, LocalizedError {
        var errorDescription: String? { "the disk is full" }
    }

    /// A journal as an interrupted copy of `src` leaves it: `offset` good bytes of it in `staging`.
    private func interruptedCopy(_ src: URL, to dst: URL, staging: URL, offset: Int) throws -> JobJournal {
        try Data(contentsOf: src).prefix(offset).write(to: staging)
        var j = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        j.created = Date(timeIntervalSinceNow: -60)
        j.apply(.started(index: 0, staging: staging))
        j.apply(.copied(index: 0, point: ResumePoint(staging: staging, offset: Int64(offset))))
        return j
    }

    // MARK: Integrity of a partial copy

    /// The partial copy keeps its inode and length but its bytes are changed in place: resuming from it would publish
    /// them. It's copied from the start instead, and the changed file is kept.
    @Test func aPartialCopyChangedInPlaceIsNeverPublished() async throws {
        let src = try s.randomFile("src/big.bin", size: 12 << 20, seed: 7)
        let dst = try s.folder("dst")
        let staging = dst.appendingPathComponent(".big.bin.porpoise-0000aaaa")
        let j = try interruptedCopy(src, to: dst, staging: staging, offset: 9 << 20)
        c.journals.save(j)
        // Same inode, same size: only the bytes differ.
        let h = try FileHandle(forWritingTo: staging)
        try h.write(contentsOf: Data("EVIL".utf8))
        try h.close()

        let plan = try #require(c.recoveryPlans().first)
        #expect(plan.resumePoints[src]?.offset == 9 << 20)  // looks resumable until its bytes are read
        var finished = false
        c.recover(plan, window: nil) { _ in finished = true }
        let check = try #require(c.activities.first)
        #expect(check.title == "Checking before resuming: Copying to “dst”")
        #expect(await poll { finished })
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
        #expect(try Data(contentsOf: staging).prefix(4) == Data("EVIL".utf8))
        #expect(ui.errors.contains { $0.hasPrefix("The partial copy of “big.bin” was changed meanwhile") && $0.contains(staging.path) })
        #expect(check.state.isEnded)
        #expect(await poll { c.journals.all().isEmpty })
    }

    /// The control: an intact partial copy still continues from where it stopped.
    @Test func anIntactPartialCopyStillResumes() async throws {
        let src = try s.randomFile("src/big.bin", size: 12 << 20, seed: 8)
        let dst = try s.folder("dst")
        let staging = dst.appendingPathComponent(".big.bin.porpoise-0000bbbb")
        c.journals.save(try interruptedCopy(src, to: dst, staging: staging, offset: 9 << 20))
        let plan = try #require(c.recoveryPlans().first)
        var started: FileJob?
        ui.onJobStarted = { started = $0 }
        var finished = false
        c.recover(plan, window: nil) { _ in finished = true }
        #expect(await poll { finished })
        #expect(started?.resumePoints[src]?.offset == 9 << 20)
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(ui.errors.isEmpty)
    }

    // MARK: Ownership

    /// Discard removes the job's partial copies, but only while they are what the plan saw.
    @Test func discardKeepsAnItemThatReplacedAPartialCopyAfterThePlan() throws {
        let src = try s.randomFile("src/big.bin", size: 12 << 20, seed: 9)
        let dst = try s.folder("dst")
        let staging = dst.appendingPathComponent(".big.bin.porpoise-0000cccc")
        c.journals.save(try interruptedCopy(src, to: dst, staging: staging, offset: 9 << 20))
        let plan = try #require(c.recoveryPlans().first)
        #expect(plan.resumePoints[src] != nil)
        // While the dialog is up, another app puts its own file there.
        try FileManager.default.removeItem(at: staging)
        try Data("someone else's".utf8).write(to: staging)
        c.discard(plan)
        #expect(try String(contentsOf: staging, encoding: .utf8) == "someone else's")
        #expect(ui.errors.contains { $0.contains(staging.path) })
        #expect(c.journals.all().isEmpty)

        // Unchanged, it goes.
        let other = dst.appendingPathComponent(".big.bin.porpoise-0000dddd")
        c.journals.save(try interruptedCopy(src, to: dst, staging: other, offset: 9 << 20))
        c.discard(try #require(c.recoveryPlans().first))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    /// Before any checkpoint there is no inode to go by: an item at the job's hidden name older than the job isn't its.
    @Test func aPartialCopyOlderThanTheJobIsNotTreatedAsItsOwn() throws {
        let src = try s.file("src/a.txt", "a")
        let dst = try s.folder("dst")
        let staging = try s.file("dst/.a.txt.porpoise-0000eeee", "not from this job")
        var j = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        j.created = Date(timeIntervalSinceNow: 3600)  // the job began after the item was made
        j.apply(.started(index: 0, staging: staging))
        try FileManager.default.removeItem(at: src)
        let plan = try #require(FileOperationsController.plan(j))
        #expect(plan.partials.isEmpty)
        c.discard(plan)
        #expect(FileManager.default.fileExists(atPath: staging.path))

        // Made after the job began: its own, and removed.
        j.created = Date(timeIntervalSinceNow: -60)
        let ours = try #require(FileOperationsController.plan(j))
        #expect(ours.partials == [staging])
        c.discard(ours)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    /// Deleting goes by name: an item that took a pending item's place is not deleted, whether it appeared before the
    /// plan was made or while it waited for an answer.
    @Test func aReplacedItemIsNeverDeletedByAResumedDeletion() async throws {
        let a = try s.file("trash/a.txt", "a"), b = try s.file("trash/b.txt", "b"), d = try s.file("trash/d.txt", "d")
        var j = JobJournal(id: UUID(), kind: .delete, sources: [a, b, d], destination: nil)
        j.items[2].state = .started
        c.journals.save(j)
        // Before the plan: replaced.
        try FileManager.default.removeItem(at: a)
        try "new a".write(to: a, atomically: false, encoding: .utf8)
        let plan = try #require(c.recoveryPlans().first)
        #expect(plan.sources == [b, d])
        #expect(plan.notes == ["“a.txt” was replaced by another item since: it isn't deleted."])
        // After the plan: replaced too.
        try FileManager.default.removeItem(at: b)
        try "new b".write(to: b, atomically: false, encoding: .utf8)
        c.recover(plan, window: nil)
        #expect(await poll { !FileManager.default.fileExists(atPath: d.path) })
        #expect(try String(contentsOf: a, encoding: .utf8) == "new a")
        #expect(try String(contentsOf: b, encoding: .utf8) == "new b")
        #expect(ui.errors.contains("“b.txt” was replaced or removed since: it isn't deleted."))
    }

    /// A moved copy that can't be read completely proves nothing: the original stays.
    @Test(.enabled(if: geteuid() != 0)) func anUnreadableMovedCopyKeepsTheOriginal() async throws {
        let src = try s.folder("src/album")
        try s.file("src/album/one.jpg", "1")
        try s.file("src/album/locked/two.jpg", "2")
        let dst = try s.folder("dst")
        let target = dst.appendingPathComponent("album")
        try FileManager.default.copyItem(at: src, to: target)
        try FileManager.default.removeItem(at: target.appendingPathComponent("locked/two.jpg"))  // the copy lacks it
        let locked = [src.appendingPathComponent("locked"), target.appendingPathComponent("locked")]
        for l in locked { chmod(l.path, 0) }
        defer { for l in locked { chmod(l.path, 0o755) } }
        var j = JobJournal(id: UUID(), kind: .move, sources: [src], destination: dst)
        j.apply(.placed(index: 0, target: target))
        c.journals.save(j)
        let plan = try #require(c.recoveryPlans().first)
        c.recover(plan, window: nil)
        #expect(await poll { ui.errors.contains { $0.hasPrefix("“album” wasn't removed: its moved copy differs") } })
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("one.jpg").path))
    }

    // MARK: The record of the work

    /// Interrupted while it checks (the app quits): nothing is handed on and the journal is still there, with what was
    /// finished recorded, so the rest is offered again.
    @Test func anInterruptedRecoveryKeepsItsJournal() async throws {
        let moved = try s.file("src/moved.txt", "moved")
        let waiting = try s.file("src/waiting.txt", "waiting")
        let dst = try s.folder("dst")
        try FileManager.default.copyItem(at: moved, to: dst.appendingPathComponent("moved.txt"))
        var j = JobJournal(id: UUID(), kind: .move, sources: [moved, waiting], destination: dst)
        j.apply(.placed(index: 0, target: dst.appendingPathComponent("moved.txt")))
        c.journals.save(j)
        let plan = try #require(c.recoveryPlans().first)
        let reached = Flag(), go = DispatchSemaphore(value: 0)
        defer { go.signal(); c.journals.writeFault = nil }
        c.journals.writeFault = { _ in
            reached.set()
            #expect(go.wait(timeout: .now() + 30) == .success)
        }
        c.recover(plan, window: nil)
        try #require(await poll { reached.isSet })
        let activity = try #require(c.activities.first)
        let control = activity.verificationControl ?? activity.control
        // interruptAll waits for this journal write. Release it only after interruption, even if the main
        // thread is descheduled before calling interruptAll; a timed release could let recovery finish first.
        Thread {
            guard waitUntil(30, { control.isInterrupted }) else {
                Issue.record("The controller never interrupted the held recovery")
                return
            }
            go.signal()
        }.start()
        c.interruptAll()
        c.journals.writeFault = nil
        #expect(await poll { c.activities.first?.state == .interrupted })
        await expectStays(for: 0.3) { FileManager.default.fileExists(atPath: waiting.path) }
        let again = try #require(c.recoveryPlans().first)
        #expect(again.id == plan.id)
        #expect(again.sources == [waiting] && again.unfinishedMoves.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    /// Cancelled from the Activity window: the same.
    @Test func aCancelledRecoveryKeepsItsJournal() async throws {
        let waiting = try s.file("src/waiting.txt", "waiting")
        let dst = try s.folder("dst")
        c.journals.save(JobJournal(id: UUID(), kind: .copy, sources: [waiting], destination: dst))
        let plan = try #require(c.recoveryPlans().first)
        let reached = Flag(), go = DispatchSemaphore(value: 0)
        c.journals.writeFault = { _ in
            reached.set()
            _ = go.wait(timeout: .now() + 30)
        }
        c.recover(plan, window: nil)
        #expect(await poll { reached.isSet })
        let check = try #require(c.activities.first)
        c.cancel(check)
        go.signal()
        #expect(await poll { check.state == .cancelled })
        c.journals.writeFault = nil
        await expectStays(for: 0.3) { !FileManager.default.fileExists(atPath: dst.appendingPathComponent("waiting.txt").path) }
        #expect(c.recoveryPlans().map(\.id) == [plan.id])
    }

    /// If the journal can't be written, the job isn't resumed without one: the old record stays and the reason is shown.
    @Test func aJournalThatCannotBeWrittenStopsTheResume() async throws {
        let waiting = try s.file("src/waiting.txt", "waiting")
        let dst = try s.folder("dst")
        c.journals.save(JobJournal(id: UUID(), kind: .copy, sources: [waiting], destination: dst))
        let plan = try #require(c.recoveryPlans().first)
        c.journals.writeFault = { _ in throw WriteFailure() }
        c.recover(plan, window: nil)
        #expect(await poll { ui.errors.contains { $0.hasPrefix("Porpoise couldn't update its record") && $0.contains("the disk is full") } })
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("waiting.txt").path))
        c.journals.writeFault = nil
        #expect(c.recoveryPlans().map(\.id) == [plan.id])
    }

    /// The resumed job's own journal can't be written: it runs, the old record stays while it does (so an interruption
    /// still finds it), and goes when the job ends.
    @Test func aFailedHandOffKeepsTheOldRecordUntilTheJobEnds() async throws {
        let src = try s.randomFile("src/big.bin", size: 32 << 20, seed: 10)
        let dst = try s.folder("dst")
        let old = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        c.journals.save(old)
        let plan = try #require(c.recoveryPlans().first)
        let oldFile = s.path("journals/\(old.id.uuidString).json")
        c.journals.writeFault = { url in if url != oldFile { throw WriteFailure() } }
        c.prepareJob = { job in
            job.allowsClone = false
            job.chunkDelay = 0.03
            job.publishInterval = 0
        }
        var finished = false
        c.recover(plan, window: nil) { _ in finished = true }
        #expect(await poll { ui.errors.contains { $0.hasPrefix("Porpoise couldn't write the record of the resumed job") } })
        #expect(FileManager.default.fileExists(atPath: oldFile.path))
        #expect(c.activities.last?.state.isEnded == false)
        c.journals.writeFault = nil
        #expect(await poll { finished })
        #expect(await poll { c.journals.all().isEmpty })
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Data(contentsOf: src))
    }

    /// The resumed job's journal names the one it replaces. Stopped again, there is exactly one record of the work,
    /// and a crash between writing the new journal and removing the old one leaves one too.
    @Test func handingOnLeavesExactlyOneRecordAtEveryMoment() async throws {
        let src = try s.randomFile("src/big.bin", size: 32 << 20, seed: 11)
        let dst = try s.folder("dst")
        let old = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        c.journals.save(old)
        let plan = try #require(c.recoveryPlans().first)
        c.prepareJob = { job in
            job.allowsClone = false
            job.chunkDelay = 0.03
            job.publishInterval = 0
        }
        c.recover(plan, window: nil)
        #expect(await poll { (c.activities.last?.progress?.doneBytes ?? 0) > 4 << 20 })
        c.interruptAll()
        let records = c.journals.all()
        #expect(records.count == 1)
        let next = try #require(records.first)
        #expect(next.id != old.id && next.replaces == old.id)

        // A crash after the new journal was written, before the old one was removed: both files are there.
        let store = JournalStore(folder: s.path("crashed"))
        let first = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        var second = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: dst)
        second.replaces = first.id
        store.save(first)
        store.save(second)
        #expect(store.all().map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: s.path("crashed/\(first.id.uuidString).json").path))
        // Before the new one was written: only the old one, offered as before.
        let before = JournalStore(folder: s.path("crashed-before"))
        before.save(first)
        #expect(before.all().map(\.id) == [first.id])
    }

    /// An old journal without the field still reads.
    @Test func journalsWrittenBeforeHandOffsStillRead() throws {
        let src = try s.file("src/a.txt", "a")
        let j = JobJournal(id: UUID(), kind: .copy, sources: [src], destination: try s.folder("dst"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as? [String: Any])
        json.removeValue(forKey: "replaces")
        try FileManager.default.createDirectory(at: s.path("journals"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: s.path("journals/\(j.id.uuidString).json"))
        #expect(c.journals.all().map(\.id) == [j.id])
    }
}
