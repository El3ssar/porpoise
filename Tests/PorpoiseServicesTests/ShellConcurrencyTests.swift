import Foundation
import Testing

@testable import PorpoiseServices

/// Shell.run from many threads at once.
@Suite struct ShellConcurrencyTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// More callers than cores, each with its own stdin and outputs: every run gets back exactly its own. (Shell's
    /// pipe work runs on queues of its own so that callers filling Swift concurrency's few threads can't starve it;
    /// that can't be shown here without starving the test runner itself, which uses the same threads.)
    @Test func manyBlockingCallersAtOnceAllFinish() {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 3
        let ok = Counter()
        let finished = DispatchGroup()
        for i in 0..<callers {
            DispatchQueue.global().async(group: finished) {
                let r = try? Shell.run("/bin/sh", ["-c", "cat; echo \(i) >&2"], stdin: Data("hello \(i)".utf8), timeout: 20)
                if r?.out == Data("hello \(i)".utf8) && r?.err == "\(i)\n" { ok.add() }
            }
        }
        #expect(finished.wait(timeout: .now() + 30) == .success)
        #expect(ok.value == callers)
    }
}
