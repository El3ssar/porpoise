import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Plays the user for FileOperationsController: answers conflicts from a script, confirms or declines questions (ticking
/// "Do not ask again" when told to), reviews an App Cleanup when given a selection, and remembers everything it was
/// shown. It never agrees to authenticate as administrator.
public final class ScriptedUI: FileOperationsUI {
    /// Answers to name conflicts, in order. A conflict nobody scripted fails the test and cancels the job.
    public var conflictAnswers: [ConflictAnswer]
    public var asyncConflict: ((ConflictInfo, JobControl, @escaping (ConflictAnswer) -> Void) -> Void)?
    public var didCancelConflict = false
    public var onJobStarted: ((FileJob) -> Void)?
    public var confirms: Bool
    /// Ticks "Do not ask again" on the questions it confirms.
    public var dontAskAgain = false
    /// App Cleanup's review: nil leaves it to the controller (no review); else the items left selected, or nil to cancel.
    public var cleanupSelection: [URL]?? = nil
    public private(set) var reviewedCleanup: [URL] = []

    public private(set) var questions: [PorpoiseServices.Confirmation] = []
    public private(set) var conflicts: [ConflictInfo] = []
    public private(set) var errors: [String] = []
    public private(set) var authorizationErrors: [String] = []
    public private(set) var finishedJobs: [FileJob] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(conflicts: [ConflictAnswer] = [], confirms: Bool = true, dontAskAgain: Bool = false) {
        conflictAnswers = conflicts
        self.confirms = confirms
        self.dontAskAgain = dontAskAgain
    }

    public func confirm(_ question: PorpoiseServices.Confirmation, window: AnyObject?) -> (confirmed: Bool, dontAskAgain: Bool) {
        questions.append(question)
        if question.confirmTitle == "Authenticate" { return (false, false) }
        return (confirms, confirms && dontAskAgain)
    }

    public func showErrors(_ errors: [String], window: AnyObject?) { self.errors += errors }

    public func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer {
        conflicts.append(info)
        guard !conflictAnswers.isEmpty else {
            Issue.record("Unexpected conflict for “\(info.destination.name)”")
            return ConflictAnswer(.cancel)
        }
        return conflictAnswers.removeFirst()
    }

    public func resolveConflict(
        _ info: ConflictInfo, kind: FileOperationKind, window: AnyObject?, job: JobControl, completion: @escaping (ConflictAnswer) -> Void
    ) {
        if let asyncConflict { asyncConflict(info, job, completion) } else { completion(resolveConflict(info, kind: kind)) }
    }
    public func cancelConflict(for job: JobControl) { didCancelConflict = true }
    public var reviewsAppCleanup: Bool { cleanupSelection != nil }
    public func reviewAppCleanup(_ items: [URL], window: AnyObject?, completion: @escaping ([URL]?) -> Void) {
        reviewedCleanup = items
        completion(cleanupSelection ?? nil)
    }
    public func jobStarted(_ activity: Activity) { if let job = activity.job { onJobStarted?(job) } }
    public func jobProgressed(_ activity: Activity, _ progress: JobProgress) {}

    public func jobFinished(_ activity: Activity) {
        if let job = activity.job { finishedJobs.append(job) }
        // The controller finishes its bookkeeping in the same main-queue turn, before a waiter resumes.
        let w = waiting
        waiting = [:]
        w.values.forEach { $0.resume() }
    }

    public func showAuthorizationError(_ message: String) { authorizationErrors.append(message) }

    /// Waits until the next job reports it has finished; a job that never comes fails the test after `timeout`
    /// instead of hanging the run (a time limit can't interrupt a continuation).
    @MainActor public func nextJobFinished(timeout: TimeInterval = 20, sourceLocation: SourceLocation = #_sourceLocation) async {
        let id = UUID()
        await withCheckedContinuation { c in
            waiting[id] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
                guard let c = waiting.removeValue(forKey: id) else { return }
                Issue.record("No job finished within \(Int(timeout)) seconds", sourceLocation: sourceLocation)
                c.resume()
            }
        }
    }
}

/// A controller as the app sets it up, with a scripted user and a clipboard of its own. Its suite runs with
/// `.isolatedSettings`, which also makes it a test run: no helper, no sounds, no administrator prompt.
public func makeController(_ ui: ScriptedUI) -> FileOperationsController {
    let c = FileOperationsController()
    c.ui = ui
    c.clipboard = LocalClipboard()
    return c
}

extension FileOperationsController {
    /// Runs a job and waits for it, leaving the main queue free for its questions and results.
    @MainActor public func perform(_ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil) async throws -> [URL] {
        try await awaitCallback { c in run(kind, urls, to: folder, window: nil) { c.resume(returning: $0) } }
    }

    @MainActor public func paste(into folder: URL) async throws -> [URL] {
        try await awaitCallback { c in paste(into: folder, window: nil) { c.resume(returning: $0) } }
    }
}
