import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Shell.run from many threads at once.
@Suite struct ShellConcurrencyTests {

    /// More callers than cores, each with its own stdin and outputs: every run gets back exactly its own. (Shell's
    /// pipe work runs on queues of its own so that callers filling Swift concurrency's few threads can't starve it;
    /// that can't be shown here without starving the test runner itself, which uses the same threads.)
    @Test func manyBlockingCallersAtOnceAllFinish() async {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 3
        let ok = Counter()
        let finished = DispatchGroup()
        for i in 0..<callers {
            // Threads of their own: GCD's shared queues get about one thread per core, and on a small machine the
            // test runner's own blocked threads can hold those for longer than the test waits.
            finished.enter()
            Thread {
                let r = try? Shell.run("/bin/sh", ["-c", "cat; echo \(i) >&2"], stdin: Data("hello \(i)".utf8), timeout: 120)
                if r?.out == Data("hello \(i)".utf8) && r?.err == "\(i)\n" { ok.add() }
                finished.leave()
            }.start()
        }
        // Waited for off the cooperative pool, longer than a run's own timeout (plus its kill grace).
        let waited = await offThePool { finished.wait(timeout: .now() + 300) }
        #expect(waited == .success)
        #expect(ok.value == callers)
    }
}
