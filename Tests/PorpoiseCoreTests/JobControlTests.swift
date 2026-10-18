import Foundation
import Testing

@testable import PorpoiseCore

struct JobControlTests {
    @Test(arguments: ["resume", "cancel", "interrupt"])
    func aPausedWorkerWakesForEveryStopOrResume(_ action: String) throws {
        let control = JobControl(), entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let outcome = NSLock()
        var result: FileOperationError?
        control.pause()
        Thread {
            entered.signal()
            do { try control.checkpoint() } catch { outcome.withLock { result = error as? FileOperationError } }
            done.signal()
        }.start()
        #expect(entered.wait(timeout: .now() + 60) == .success)
        #expect(control.isPaused && !control.hasEnded)
        switch action {
        case "cancel": control.cancel()
        case "interrupt": control.interrupt()
        default: control.resume()
        }
        #expect(done.wait(timeout: .now() + 60) == .success)
        let error = outcome.withLock { result }
        if action == "cancel" { if case .cancelled? = error {} else { Issue.record("Expected cancellation") } }
        if action == "interrupt" { if case .interrupted? = error {} else { Issue.record("Expected interruption") } }
        if action == "resume" { #expect(error == nil) }
        control.finish()
        #expect(control.hasEnded)
    }

    @Test func diskAdapterObservesTheOwningControl() throws {
        let control = JobControl(), disk = control.asDiskCancellation()
        try disk.check()
        control.interrupt()
        #expect(disk.isCancelled)
        #expect(throws: CancellationError.self) { try disk.check() }
        let independent = JobControl().asDiskCancellation()
        independent.cancel()
        #expect(throws: CancellationError.self) { try independent.check() }
    }

    @Test func asyncPauseRemainsCancellableWithoutBlockingTheExecutor() async {
        let control = JobControl()
        control.pause()
        let task = Task { try await control.checkpointAsync() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        control.interrupt()
        await #expect(throws: FileOperationError.self) { try await control.checkpointAsync() }
        let ready = JobControl()
        await #expect(throws: Never.self) { try await ready.checkpointAsync() }
    }
}
