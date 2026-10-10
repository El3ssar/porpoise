import Foundation
import Testing
import PorpoiseCore
@testable import PorpoiseServices

/// Plays the user for FileOperationsController: answers conflicts from a script, confirms or declines questions,
/// and remembers everything it was shown. It never agrees to authenticate as administrator.
final class ScriptedUI: FileOperationsUI {
    /// Answers to name conflicts, in order. A conflict nobody scripted fails the test and cancels the job.
    var conflictAnswers: [ConflictAnswer]
    var confirms: Bool

    private(set) var questions: [PorpoiseServices.Confirmation] = []
    private(set) var conflicts: [ConflictInfo] = []
    private(set) var errors: [String] = []
    private(set) var authorizationErrors: [String] = []
    private(set) var finishedJobs: [FileJob] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(conflicts: [ConflictAnswer] = [], confirms: Bool = true) {
        conflictAnswers = conflicts
        self.confirms = confirms
    }

    func confirm(_ question: PorpoiseServices.Confirmation, window: AnyObject?) -> (confirmed: Bool, dontAskAgain: Bool) {
        questions.append(question)
        if question.confirmTitle == "Authenticate" { return (false, false) }
        return (confirms, false)
    }

    func showErrors(_ errors: [String], window: AnyObject?) { self.errors += errors }

    func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer {
        conflicts.append(info)
        guard !conflictAnswers.isEmpty else {
            Issue.record("Unexpected conflict for “\(info.destination.name)”")
            return ConflictAnswer(.cancel)
        }
        return conflictAnswers.removeFirst()
    }

    func jobStarted(_ job: FileJob) {}
    func jobProgressed(_ job: FileJob, _ progress: JobProgress) {}

    func jobFinished(_ job: FileJob) {
        finishedJobs.append(job)
        // The controller finishes its bookkeeping in the same main-queue turn, before a waiter resumes.
        let w = waiting
        waiting = []
        w.forEach { $0.resume() }
    }

    func showAuthorizationError(_ message: String) { authorizationErrors.append(message) }

    /// Waits until the next job reports it has finished.
    @MainActor func nextJobFinished() async {
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// A controller as the app sets it up, with a scripted user and a clipboard of its own. Settings point at a
/// throwaway domain and the run counts as a test: no helper, no sounds, no administrator prompt.
@MainActor func makeController(_ ui: ScriptedUI) -> FileOperationsController {
    _ = TestSettings.ready
    let c = FileOperationsController()
    c.ui = ui
    c.clipboard = LocalClipboard()
    return c
}

enum TestSettings {
    static let domain = "app.porpoise.tests.fileoperations"
    static let ready: Void = {
        Settings.isTesting = true
        Settings.store = UserDefaults(suiteName: domain)!
    }()

    /// Trash origins are written to the store; suites that write it remove the domain when done.
    static func reset() { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
}

extension FileOperationsController {
    /// Runs a job and waits for it, leaving the main queue free for its questions and results.
    @MainActor func perform(_ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil) async -> [URL] {
        await withCheckedContinuation { c in run(kind, urls, to: folder, window: nil) { c.resume(returning: $0) } }
    }

    @MainActor func paste(into folder: URL) async -> [URL] {
        await withCheckedContinuation { c in paste(into: folder, window: nil) { c.resume(returning: $0) } }
    }
}
