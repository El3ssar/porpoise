import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct TransferControlTests {
    @Test func aRunningToolPausesWithoutRestartingAndCancelsCleanly() async throws {
        let s = try Scratch("tool-pause")
        let output = s.path("output")
        let script = try s.file(
            "stream.sh",
            """
            i=0
            while [ "$i" -lt 100 ]; do
                printf x
                i=$((i + 1))
                sleep 0.02
            done
            """)
        let job = FileJob(kind: .copy, sources: [])
        let control = Shell.TransferControl(isPaused: { job.isPaused }, isCancelled: { job.isCancelled })
        let work = Task.detached {
            try Shell.withTransferControl(control) {
                try Shell.run("/bin/sh", [script.path], stdoutFile: output, timeout: 10)
            }
        }
        func bytes() -> Int { ((try? Data(contentsOf: output)) ?? Data()).count }
        #expect(await eventually(5) { bytes() >= 3 })
        job.pause()
        try await Task.sleep(for: .milliseconds(150))
        let held = bytes()
        try await Task.sleep(for: .milliseconds(200))
        #expect(bytes() == held)
        job.resume()
        #expect(await eventually(5) { bytes() > held + 2 })
        job.pause()
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        do {
            _ = try await work.value
            Issue.record("Cancelled process returned success")
        } catch FileOperationError.cancelled {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(bytes() < 100)
        // Thread-local scope cannot cancel an unrelated command on this thread.
        #expect(try Shell.run("/usr/bin/true", []).status == 0)
    }
}
