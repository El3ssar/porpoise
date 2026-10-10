import Foundation
import Testing
@testable import PorpoiseServices

/// Shell.run blocks its caller; many callers at once must not starve the threads that feed and drain its pipes.
@Suite struct ShellConcurrencyTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func manyBlockingCallersAtOnceAllFinish() {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 3
        let ok = Counter()
        let finished = DispatchGroup()
        for _ in 0..<callers {
            // Swift concurrency tasks, like tests calling providers: each blocks a pool thread while it waits.
            finished.enter()
            Task.detached {
                defer { finished.leave() }
                let r = try? Shell.run("/bin/sh", ["-c", "cat; echo err >&2"], stdin: Data("hello".utf8))
                if r?.out == Data("hello".utf8) && r?.err == "err\n" { ok.add() }
            }
        }
        // A plain wait with a deadline: with the pool deadlocked, nothing async could wake this test up.
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(ok.value == callers)
    }
}
