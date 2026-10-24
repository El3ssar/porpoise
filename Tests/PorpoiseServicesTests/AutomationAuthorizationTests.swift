import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct AutomationAuthorizationTests {
    @Test func deniedAutomationNeverReachesAuthorization() {
        let controller = FileOperationsController()
        var completed = false
        // With normal retry this generates administrator commands and attempts authorization.
        // The automation guard must return before inspecting paths, prompting or invoking the helper.
        controller.retryDenied(
            .move, [URL(fileURLWithPath: "/nonexistent/automation")], targets: [:],
            to: URL(fileURLWithPath: "/Library"), window: nil, allowAuthorization: false
        ) { results in
            #expect(results.isEmpty)
            completed = true
        }
        #expect(completed && controller.activities.isEmpty)
    }

    @Test func realDeniedMoveNeverEntersHelperOrAdministratorPrompt() async throws {
        let scratch = try Scratch(), source = try scratch.file("source"), destination = try scratch.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path) }
        let controller = FileOperationsController(), ui = ScriptedUI()
        controller.ui = ui
        var authorizationCalls = 0
        controller.authorizationAttempted = { authorizationCalls += 1 }
        // W-245: nor root by any path: the helper (or the administrator prompt) is never asked.
        let elevated = Locked(0)
        let real = FileOperationsController.elevate
        FileOperationsController.elevate = { _, _, _ in
            elevated.change { $0 += 1 }; return .cancelled
        }
        defer { FileOperationsController.elevate = real }
        controller.run(.move, [source], to: destination, window: nil, allowAuthorization: false)
        await ui.nextJobFinished()
        #expect(elevated.value == 0)
        #expect(controller.activities.last?.job?.denied == [source])
        #expect(authorizationCalls == 0 && ui.questions.isEmpty && ui.authorizationErrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(controller.activities.last?.allowsAuthorization == false)
    }

    @Test func unapprovedQueueCannotRunAndRecoveryKeepsNoAuthorization() async throws {
        let scratch = try Scratch(), source = try scratch.file("source"), destination = try scratch.folder("destination")
        let controller = FileOperationsController()
        let pending = controller.queueAutomation(.move, sources: [source], destination: destination, window: nil)
        #expect(pending.state == .waiting && !pending.allowsAuthorization && pending.job == nil)
        controller.retry(pending, window: nil)
        #expect(controller.activities.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        controller.finishAutomationApproval(pending, approved: false)
        #expect(controller.activities.isEmpty && FileManager.default.fileExists(atPath: source.path))
        var journal = JobJournal(id: UUID(), kind: .copy, sources: [source], destination: destination)
        journal.allowsAuthorization = false
        let decoded = try JSONDecoder().decode(JobJournal.self, from: JSONEncoder().encode(journal))
        #expect(FileOperationsController.plan(decoded)?.allowsAuthorization == false)
        journal.allowsAuthorization = nil
        #expect(FileOperationsController.plan(journal)?.allowsAuthorization == true)
    }
}
