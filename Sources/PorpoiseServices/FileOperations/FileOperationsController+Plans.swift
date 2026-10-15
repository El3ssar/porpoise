import Foundation
import PorpoiseCore

extension FileOperationsController {
    /// Queue a mixed-operation plan, or explicitly resume its saved journal. Main thread only.
    /// The engine must validate/reconcile a recovered running step before changing disk again.
    @discardableResult
    public func enqueuePlan(
        _ journal: PlanJournal, execute: @escaping (PlanStep, PlanStepContext) throws -> Void
    ) throws -> Activity {
        guard !activities.contains(where: { $0.id == journal.id && !$0.state.isEnded }) else {
            throw FileOperationError.failed("This plan is already queued or running.")
        }
        guard journal.version == 1, Set(journal.steps.map { $0.operation.id }).count == journal.steps.count else {
            throw FileOperationError.failed("This plan has an unsupported version or duplicate step IDs.")
        }
        try planJournals.save(journal)
        isInterrupting = false
        activities.removeAll { $0.id == journal.id && $0.state.isEnded }
        let job = PlanJob(journal: journal, store: planJournals)
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil, id: journal.id)
        activity.planJob = job
        activity.planProgress = PlanProgress(
            completedSteps: journal.steps.filter { $0.state == .completed }.count, totalSteps: journal.steps.count,
            currentTitle: "", stepFraction: 0)
        activity.retryPlan = { [weak self, weak activity] in
            guard let self, let activity else { return }
            do {
                _ = try self.enqueuePlan(job.journal, execute: execute)
                self.activities.removeAll { $0 === activity }
            } catch {
                activity.errors = [error.localizedDescription]
                self.activityDidChange()
            }
        }
        activity.start = { [weak self, weak activity] in
            guard let self, let activity, activity.state == .queued else { return }
            self.began(activity)
            job.onProgress = { [weak self, weak activity] progress in
                DispatchQueue.main.async {
                    activity?.planProgress = progress
                    self?.activityDidChange()
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var errors: [String] = []
                do { try job.run(execute: execute) } catch {
                    if !job.isCancelled { errors = [error.localizedDescription] }
                }
                DispatchQueue.main.async { self.ended(activity, errors: errors) }
            }
        }
        enqueue(activity)
        return activity
    }

    /// Engine-defined payloads must be decoded and validated before calling `enqueuePlan` to resume them.
    public func recoverablePlans() throws -> [PlanJournal] {
        let live = Set(activities.filter { !$0.state.isEnded }.map(\.id))
        return try planJournals.all().filter { !live.contains($0.id) }
    }
}
