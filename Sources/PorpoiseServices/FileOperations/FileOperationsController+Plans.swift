import Foundation
import PorpoiseCore

extension FileOperationsController {
    /// Queue a mixed-operation plan, or explicitly resume its saved journal. Main thread only.
    /// The engine must validate/reconcile a recovered running step before changing disk again.
    @discardableResult
    public func enqueuePlan(
        _ journal: PlanJournal, execute: @escaping (PlanStep, PlanStepContext) throws -> Void
    ) throws -> Activity {
        guard !pendingPlans.contains(journal.id), !activities.contains(where: { $0.id == journal.id && !$0.state.isEnded }) else {
            throw FileOperationError.failed("This plan is already queued or running.")
        }
        guard journal.version == 1, Set(journal.steps.map { $0.operation.id }).count == journal.steps.count else {
            throw FileOperationError.failed("This plan has an unsupported version or duplicate step IDs.")
        }
        try planJournals.save(journal)
        return enqueueSavedPlan(journal, execute: execute)
    }

    /// Saves the baseline off main before exposing an executable Activity. Completion runs on main.
    public func enqueuePlanAsync(
        _ journal: PlanJournal, window: AnyObject? = nil, execute: @escaping (PlanStep, PlanStepContext) throws -> Void,
        completion: @escaping (Result<Activity, Error>) -> Void
    ) {
        guard !pendingPlans.contains(journal.id), !activities.contains(where: { $0.id == journal.id && !$0.state.isEnded }),
            journal.version == 1, Set(journal.steps.map { $0.operation.id }).count == journal.steps.count
        else { completion(.failure(FileOperationError.failed("This plan is invalid or already running."))); return }
        pendingPlans.insert(journal.id)
        let store = planJournals
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = Result { try store.save(journal) }
            DispatchQueue.main.async {
                self.pendingPlans.remove(journal.id)
                switch saved {
                case .failure(let error): completion(.failure(error))
                case .success:
                    guard !self.activities.contains(where: { $0.id == journal.id && !$0.state.isEnded }) else {
                        completion(.failure(FileOperationError.failed("This plan is already running."))); return
                    }
                    let activity = self.enqueueSavedPlan(journal, asynchronousPersistence: true, execute: execute)
                    activity.originWindow = window
                    completion(.success(activity))
                }
            }
        }
    }

    private func enqueueSavedPlan(
        _ journal: PlanJournal, asynchronousPersistence: Bool = false, execute: @escaping (PlanStep, PlanStepContext) throws -> Void
    ) -> Activity {
        isInterrupting = false
        activities.removeAll { $0.id == journal.id && $0.state.isEnded }
        let job = PlanJob(journal: journal, store: planJournals)
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil, id: journal.id)
        activity.planJob = job
        activity.asynchronousPersistence = asynchronousPersistence
        activity.planProgress = PlanProgress(
            completedSteps: journal.steps.filter { $0.state == .completed }.count, totalSteps: journal.steps.count,
            currentTitle: "", stepFraction: 0)
        activity.retryPlan = { [weak self, weak activity] in
            guard let self, let activity else { return }
            if asynchronousPersistence {
                self.enqueuePlanAsync(job.journal, window: activity.originWindow, execute: execute) { result in
                    if case .failure(let error) = result { activity.errors = [error.localizedDescription]; self.activityDidChange() }
                }
                return
            }
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
