import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct SyncJobsTests {
    @Test func journalsCheckpointMixedStepsAndRecoverRunningPublication() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/d/a", "finished"); try scratch.file("left/d/b", "remaining")
        let plan = SyncPlanner.plan(try SyncScanner.compare(left, right).comparison, mode: .backup)
        let journal = try SyncJobs.journal(plan, title: "Backup", leftRoot: left, rightRoot: right)
        let store = PlanJournalStore(folder: scratch.path("journal"))
        let first = PlanJob(journal: journal, store: store)
        #expect(throws: (any Error).self) {
            try first.run { step, context in
                try SyncJobs.execute(step, context: context)
                if plan.steps[context.index].path == "d/a" {
                    // Simulate the process disappearing after rename but before recording completion.
                    throw URLError(.networkConnectionLost)
                }
            }
        }
        #expect(scratch.read("right/d/a") == "finished")
        let saved = try #require(store.all().first)
        #expect(saved.steps.filter { $0.state == .completed }.count == 1)
        #expect(saved.steps.filter { $0.state == .running }.count == 1)
        // If recovery recopied d/a, its inode would change. Verified postconditions preserve the completed file.
        let before = try SyncScanner.scan(right).entries.first { $0.path == "d/a" }?.identity
        let recovered = PlanJob(journal: saved, store: store)
        try recovered.run(execute: SyncJobs.execute)
        #expect(try SyncScanner.scan(right).entries.first { $0.path == "d/a" }?.identity == before)
        #expect(scratch.read("right/d/b") == "remaining")
        #expect(try store.all().isEmpty)
    }
    @Test func journalRejectsConflictsAndPasswordBearingURLs() throws {
        let conflict = SyncPlan(steps: [.init(path: "a", target: .right, action: .conflict)])
        let root = URL(fileURLWithPath: "/root")
        #expect(throws: (any Error).self) { try SyncJobs.journal(conflict, title: "Conflict", leftRoot: root, rightRoot: root) }
        #expect(throws: (any Error).self) {
            try SyncJobs.journal(
                .init(steps: []), title: "Credentials", leftRoot: URL(string: "ftp://user:secret@example.test/root")!, rightRoot: root)
        }
    }
    @Test func cancellationCheckpointStopsBeforeIO() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "untouched")
        let plan = SyncPlanner.plan(try SyncScanner.compare(left, right).comparison, mode: .backup)
        let cancellation = DiskCancellation(checkpoint: { throw CancellationError() })
        #expect(throws: (any Error).self) { try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right, cancellation: cancellation) }
        #expect(scratch.listing("right").isEmpty)
    }
}
