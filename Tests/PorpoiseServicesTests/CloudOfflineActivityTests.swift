import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized) struct CloudOfflineActivityTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    private func operations(_ scratch: Scratch) -> FileOperationsController {
        let operations = FileOperationsController()
        operations.history = OperationHistory(file: scratch.url.appendingPathComponent("history"))
        return operations
    }
    @Test func lowSpacePausesAndRemoveSignalResumesTheSameRow() async throws {
        let scratch = try Scratch(), operations = operations(scratch)
        let url = URL(string: "fixture://account/file")!
        var attempts = 0
        let task = Task {
            try await operations.cloudTask(title: "Keeping “file” downloaded", sources: [url]) { context in
                attempts += 1
                if attempts == 1 { throw CloudContentError.lowSpace }
                context.progress(5, 5); context.items(1, 1)
                try await Task.sleep(for: .milliseconds(10))
                return [url]
            }
        }
        try await wait { operations.activities.last?.state == .paused }
        #expect(operations.activities.count == 1 && operations.activities[0].canPause)
        NotificationCenter.default.post(name: CloudOffline.spaceChanged, object: nil)
        #expect(try await task.value == [url])
        #expect(attempts == 2 && operations.activities.count == 1)
        #expect(operations.activities[0].state == .completed && operations.activities[0].fraction == 1)
        #expect(operations.activities[0].progress?.doneFiles == 1)
    }
    @Test func cancellingDiskPauseEndsWithoutWaitingForTheTimer() async throws {
        let scratch = try Scratch(), operations = operations(scratch)
        let task = Task { try await operations.cloudTask(title: "Keeping files", sources: []) { _ in throw CloudContentError.lowSpace } }
        try await wait { operations.activities.last?.state == .paused }
        operations.cancel(operations.activities[0])
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(operations.activities[0].state == .cancelled)
    }
    @Test func manualPauseResumeAndQuietCompletionUseNormalActivity() async throws {
        let scratch = try Scratch(), operations = operations(scratch)
        var began = false, progressed = false
        let task = Task {
            try await operations.cloudTask(title: "Keeping files", sources: []) { context in
                began = true
                try await Task.sleep(for: .milliseconds(30))
                try await context.checkpoint(); progressed = true
                return []
            }
        }
        try await wait { began }
        operations.pause(operations.activities[0])
        try await Task.sleep(for: .milliseconds(80))
        #expect(!progressed && operations.activities[0].state == .paused)
        operations.resume(operations.activities[0])
        _ = try await task.value
        #expect(progressed && operations.activities[0].state == .completed)
        let count = operations.activities.count
        _ = try await operations.cloudTask(title: "Updating offline copies", sources: [], quiet: true) { _ in [] }
        #expect(operations.activities.count == count)
    }
}

extension CloudOfflineActivityTests {
    @Test func aSpaceSignalInsideThePauseNotificationIsNotLost() async throws {
        let scratch = try Scratch(), operations = operations(scratch)
        var attempts = 0
        let observer = NotificationCenter.default.addObserver(forName: FileOperationsController.activityChanged, object: operations, queue: .main) {
            _ in
            if operations.activities.last?.state == .paused {
                NotificationCenter.default.post(name: CloudOffline.spaceChanged, object: nil)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await operations.cloudTask(title: "Keeping files", sources: []) { _ in
            attempts += 1
            if attempts == 1 { throw CloudContentError.lowSpace }
            return []
        }
        #expect(attempts == 2 && operations.activities.last?.state == .completed)
    }
}
