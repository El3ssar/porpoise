import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings, .serialized)
struct PlanJobTests {
    private func steps() -> [PlanStep] {
        [
            PlanStep(id: "copy", title: "Copy report", payload: Data("copy".utf8)),
            PlanStep(id: "trash", title: "Trash obsolete report", payload: Data("trash".utf8)),
        ]
    }

    @Test func recoverySkipsFinishedStepsAndRestoresRunningCheckpoint() throws {
        let s = try Scratch("plan-recovery")
        let store = PlanJournalStore(folder: s.path("plans"))
        let original = PlanJournal(title: "Mirror reports", steps: steps())
        let first = PlanJob(journal: original, store: store)
        var fractions: [Double] = []
        first.onProgress = { fractions.append($0.fraction) }
        #expect(throws: FileOperationError.self) {
            try first.run { step, context in
                if step.id == "copy" {
                    try Data("finished".utf8).write(to: s.path("copied.txt"))
                } else {
                    try context.saveCheckpoint(Data("validated".utf8))
                    context.report(fraction: 0.5)
                    first.interrupt()
                    try context.checkCancellation()
                }
            }
        }
        #expect(fractions.contains(0.75))
        let saved = try #require(store.all().first)
        #expect(saved.steps[0].state == .completed)
        #expect(saved.steps[1].state == .running)
        let next = PlanJob(journal: saved, store: store)
        var ran: [String] = []
        try next.run { step, context in
            ran.append(step.id)
            #expect(context.wasRunning)
            #expect(context.savedCheckpoint == Data("validated".utf8))
            try FileManager.default.moveItem(at: s.path("copied.txt"), to: s.path("trashed.txt"))
        }
        #expect(ran == ["trash"])
        #expect(try String(contentsOf: s.path("trashed.txt"), encoding: .utf8) == "finished")
        #expect(try store.all().isEmpty)
    }

    @Test func pauseHoldsTheNextStepAndCancelWakesTheWorker() async throws {
        let s = try Scratch("plan-pause")
        let store = PlanJournalStore(folder: s.path("plans"))
        let job = PlanJob(journal: PlanJournal(title: "Paused plan", steps: steps()), store: store)
        job.pause()
        let work = Task.detached {
            try job.run { _, _ in try Data("unexpected".utf8).write(to: s.path("ran")) }
        }
        #expect(await eventually(5) { (try? store.all().count) == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: s.path("ran").path))
        job.cancel()
        do {
            try await work.value
            Issue.record("Cancelled worker returned successfully")
        } catch FileOperationError.cancelled {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(job.hasEnded)
        #expect(try store.all().first?.steps.allSatisfy { $0.state == .pending } == true)
    }

    @Test func resumeContinuesAPausedStep() async throws {
        let s = try Scratch("plan-resume")
        let store = PlanJournalStore(folder: s.path("plans"))
        let job = PlanJob(journal: PlanJournal(title: "Pause inside a step", steps: [steps()[0]]), store: store)
        job.onProgress = { progress in if progress.stepFraction == 0.5 { job.pause() } }
        let work = Task.detached {
            try job.run { _, context in
                try context.saveCheckpoint(Data("halfway".utf8))
                context.report(fraction: 0.5)
                try context.checkCancellation()
                try Data("finished".utf8).write(to: s.path("result"))
            }
        }
        #expect(await eventually(5) { (try? store.all().first?.steps.first?.checkpoint) == Data("halfway".utf8) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: s.path("result").path))
        job.resume()
        try await work.value
        #expect(try String(contentsOf: s.path("result"), encoding: .utf8) == "finished")
        #expect(try store.all().isEmpty)
    }

    @Test func journalWriteFailurePreventsPhysicalWork() throws {
        let s = try Scratch("plan-save-failure")
        let blocked = try s.file("not-a-folder", "occupied")
        let store = PlanJournalStore(folder: blocked)
        let job = PlanJob(journal: PlanJournal(title: "Cannot save", steps: steps()), store: store)
        var ran = false
        #expect(throws: (any Error).self) { try job.run { _, _ in ran = true } }
        #expect(!ran)
    }

    @Test func activityQueuesMixedStepsAndRecoversTheSameIdentity() async throws {
        let s = try Scratch("plan-activity")
        let c = FileOperationsController()
        c.planJournals = PlanJournalStore(folder: s.path("plans"))
        c.history = OperationHistory(file: s.path("history.jsonl"))
        let journal = PlanJournal(title: "Mirror documents", steps: steps())
        var ran: [String] = []
        let activity = try c.enqueuePlan(journal) { step, context in
            try context.checkCancellation()
            try Data(step.payload).write(to: s.path(step.id))
        }
        #expect(activity.id == journal.id && activity.title == "Mirror documents")
        #expect(await eventually(5) { activity.state == .completed })
        #expect(activity.planProgress?.completedSteps == 2)
        #expect(activity.fraction == 1)
        #expect(try c.recoverablePlans().isEmpty)
        #expect(c.history.entries().first?.items == 2)
        #expect(FileManager.default.fileExists(atPath: s.path("copy").path))
        #expect(FileManager.default.fileExists(atPath: s.path("trash").path))

        var saved = journal
        saved.steps[0].state = .completed
        try c.planJournals.save(saved)
        let recovered = try #require(c.recoverablePlans().first)
        let resumed = try c.enqueuePlan(recovered) { step, _ in
            DispatchQueue.main.async { ran.append(step.id) }
        }
        #expect(await eventually(5) { resumed.state == .completed })
        #expect(ran == ["trash"])
    }

    @Test func duplicateIDsAreRejectedBeforeExecution() throws {
        let s = try Scratch("plan-invalid")
        let c = FileOperationsController()
        c.planJournals = PlanJournalStore(folder: s.path("plans"))
        let step = steps()[0]
        #expect(throws: FileOperationError.self) {
            try c.enqueuePlan(PlanJournal(title: "Invalid", steps: [step, step])) { _, _ in Issue.record("Must not run") }
        }
        #expect(c.activities.isEmpty)
        #expect(try c.planJournals.all().isEmpty)
    }
}
