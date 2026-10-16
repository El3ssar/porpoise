import Foundation
import PorpoiseCore

/// Versioned, credential-free bridge from reviewed sync plans to the jobs engine's durable ordered journal.
public enum SyncJobs {
    private struct Payload: Codable {
        var version = 1
        var leftRoot: URL
        var rightRoot: URL
        var step: SyncStep
    }
    public static func journal(_ plan: SyncPlan, title: String, leftRoot: URL, rightRoot: URL, id: UUID = UUID()) throws -> PlanJournal {
        guard plan.conflicts.isEmpty else { throw SyncEngineError.conflicts }
        guard leftRoot.password == nil, rightRoot.password == nil, leftRoot.query == nil, rightRoot.query == nil, leftRoot.fragment == nil,
            rightRoot.fragment == nil
        else { throw SyncEngineError.invalidState }
        let encoder = JSONEncoder()
        let steps = try plan.steps.map { step in
            let payload = Payload(leftRoot: leftRoot, rightRoot: rightRoot, step: step)
            return PlanStep(id: step.id, title: "\(step.action.rawValue.capitalized) \(step.path)", payload: try encoder.encode(payload))
        }
        return PlanJournal(id: id, title: title, steps: steps)
    }
    /// Identifies only this engine's versioned journals; unknown engine envelopes remain untouched.
    public static func restore(_ journal: PlanJournal) throws -> (plan: SyncPlan, leftRoot: URL, rightRoot: URL) {
        guard journal.version == 1, let first = journal.steps.first else { throw SyncEngineError.invalidState }
        let decoder = JSONDecoder()
        let head = try decoder.decode(Payload.self, from: first.operation.payload)
        guard head.version == 1, head.leftRoot.password == nil, head.rightRoot.password == nil, head.leftRoot.query == nil,
            head.rightRoot.query == nil, head.leftRoot.fragment == nil, head.rightRoot.fragment == nil
        else { throw SyncEngineError.invalidState }
        let steps = try journal.steps.map { record -> SyncStep in
            let payload = try decoder.decode(Payload.self, from: record.operation.payload)
            guard payload.version == 1, payload.leftRoot == head.leftRoot, payload.rightRoot == head.rightRoot,
                payload.step.id == record.operation.id, payload.step.action != .conflict
            else { throw SyncEngineError.invalidState }
            return payload.step
        }
        return (.init(steps: steps), head.leftRoot, head.rightRoot)
    }
    /// Pass this directly to FileOperationsController.enqueuePlan or PlanJob.run.
    /// Physical postconditions reconcile an operation that ran before the completion checkpoint was saved.
    public static func execute(_ step: PlanStep, context: PlanStepContext) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: step.payload)
        guard payload.version == 1, payload.step.id == step.id else { throw SyncEngineError.invalidState }
        try context.checkCancellation()
        let cancellation = DiskCancellation(checkpoint: { try context.checkCancellation() })
        try SyncExecutor.execute(payload.step, leftRoot: payload.leftRoot, rightRoot: payload.rightRoot, cancellation: cancellation)
    }
}
