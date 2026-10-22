import Foundation
import Testing

@testable import PorpoiseCore

struct TransferPolicyTests {
    @Test func exclusionsMatchNamesAndRelativePaths() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let policy = TransferPolicy(bytesPerSecond: -1, retries: 99, backoff: .infinity, exclusions: [" *.tmp ", "project/build/*", ".git", ""])
        #expect(policy.bytesPerSecond == 0 && policy.retries == 10 && policy.backoff == 1)
        #expect(policy.excludes(root.appendingPathComponent("deep/cache.tmp"), sources: [root]))
        #expect(policy.excludes(root.appendingPathComponent("build/deep/output"), sources: [root]))
        #expect(policy.excludes(root.appendingPathComponent(".git"), sources: [root]))
        #expect(!policy.excludes(root.appendingPathComponent("source.swift"), sources: [root]))
        #expect(policy.delay(forRetry: 1) == 1 && policy.delay(forRetry: 10) == 30)
    }

    @Test func automaticHoldsAndManualPauseAreIndependent() {
        let control = JobControl()
        control.setHold(.sleep, active: true)
        control.setHold(.network, active: true)
        control.resume()
        #expect(control.isPaused)
        control.setHold(.sleep, active: false)
        #expect(control.isPaused)
        control.pause()
        control.setHold(.network, active: false)
        #expect(control.isPaused)
        control.resume()
        #expect(!control.isPaused)
    }

    @Test func parallelWorkersShareOneRateBudget() async throws {
        let control = JobControl(policy: .init(bytesPerSecond: 1_000_000))
        let start = ProcessInfo.processInfo.systemUptime
        async let first: Void = control.throttleAsync(bytes: 100_000)
        async let second: Void = control.throttleAsync(bytes: 100_000)
        try await first; try await second
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.19)
    }

    @Test func pacingAndEnvironmentWaitsRemainCancellable() async {
        let control = JobControl(policy: .init(bytesPerSecond: 1))
        let worker = Task { try await control.throttleAsync(bytes: 100_000) }
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        control.setHold(.network, active: true)
        control.cancel()
        #expect(throws: FileOperationError.self) { try control.checkpoint() }
    }
}
