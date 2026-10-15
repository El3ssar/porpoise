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
        guard leftRoot.password == nil, rightRoot.password == nil else { throw SyncEngineError.invalidState }
        let encoder = JSONEncoder()
        let steps = try plan.steps.map { step in
            let payload = Payload(leftRoot: leftRoot, rightRoot: rightRoot, step: step)
            return PlanStep(id: step.id, title: "\(step.action.rawValue.capitalized) \(step.path)", payload: try encoder.encode(payload))
        }
        return PlanJournal(id: id, title: title, steps: steps)
    }
    /// Pass this directly to FileOperationsController.enqueuePlan or PlanJob.run.
    /// Physical postconditions reconcile an operation that ran before the completion checkpoint was saved.
    public static func execute(_ step: PlanStep, context: PlanStepContext) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: step.payload)
        guard payload.version == 1, payload.step.id == step.id else { throw SyncEngineError.invalidState }
        try context.checkCancellation()
        let cancellation = DiskCancellation(checkpoint: { try context.checkCancellation() })
        try SyncExecutor.execute(payload.step, leftRoot: payload.leftRoot, rightRoot: payload.rightRoot, cancellation: cancellation)
        context.report(fraction: 1)
    }
}
