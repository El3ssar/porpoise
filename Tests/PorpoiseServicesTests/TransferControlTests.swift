import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct TransferControlTests {
    @Test(arguments: [false, true])
    func aFullDiskDuringReplacementRestoresTheOldFileBeforeCancelOrRetry(_ retry: Bool) async throws {
        let s = try Scratch("transfer-full-disk")
        let source = try s.file("src/item.txt", "incoming")
        let destination = try s.folder("dst")
        let target = try s.file("dst/item.txt", "old")
        let control = FileJob(kind: .copy, sources: [source], destinationFolder: destination)
        var disposals = 0
        // The mixed local/remote engine also stages its local legs. Inject a disk-full failure
        // after the swap to check rollback, cleanup, and the user's Cancel/Retry decision.
        let transfer = RemoteTransferJob(
            kind: .copy, sources: [source], destination: destination, control: control.control,
            rule: .replace, options: .init())
        transfer.disposeReplacedItem = { old, _ in
            disposals += 1
            if disposals == 1 { throw POSIXError(.ENOSPC) }
            try FileManager.default.removeItem(at: old)
        }
        var prompts = 0
        transfer.onNoSpace = { needed in
            prompts += 1
            #expect(needed == 8)
            #expect((try? Data(contentsOf: target)) == Data("old".utf8))
            #expect((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) == ["item.txt"])
            return retry
        }
        await withCheckedContinuation { done in
            Thread {
                transfer.run(); done.resume()
            }.start()
        }
        #expect(prompts == 1)
        #expect(disposals == (retry ? 2 : 1))
        #expect(control.isCancelled == !retry)
        #expect(control.hasEnded)
        #expect(transfer.errors.isEmpty && transfer.failedSources.isEmpty)
        #expect(transfer.results == (retry ? [target] : []))
        #expect(transfer.remaining == (retry ? [] : [source]))
        #expect(try Data(contentsOf: source) == Data("incoming".utf8))
        #expect(try Data(contentsOf: target) == Data((retry ? "incoming" : "old").utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["item.txt"])
    }

    @Test func aRunningToolPausesWithoutRestartingAndCancelsCleanly() async throws {
        let s = try Scratch("tool-pause")
        let output = s.path("output")
        let pidFile = s.path("pid")
        let script = try s.file(
            "stream.sh",
            """
            echo $$ > '\(pidFile.path)'
            printf 'started\\n'
            while :; do
                printf x
                sleep 0.02
            done
            """)
        let job = FileJob(kind: .copy, sources: [])
        let control = Shell.TransferControl(isPaused: { job.isPaused }, isCancelled: { job.isCancelled })
        defer { job.cancel() }
        let work = Task {
            // Shell.run blocks: leave cooperative workers available to the pause/cancel controller.
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Shell.Result, Error>) in
                Thread {
                    do {
                        let result = try Shell.withTransferControl(control) {
                            // Cancellation ends this tool; a wall-clock deadline also counts time paused
                            // and time the controller cannot run on a loaded CI runner.
                            try Shell.run("/bin/sh", [script.path], stdoutFile: output)
                        }
                        done.resume(returning: result)
                    } catch { done.resume(throwing: error) }
                }.start()
            }
        }
        func bytes() -> Int { ((try? Data(contentsOf: output)) ?? Data()).count }
        try #require(await eventually { bytes() >= 11 })
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        /// The tool's process state from ps ("T…" once stopped by a signal), read off the cooperative pool.
        func state() async -> String {
            await offThePool {
                let r = try? Shell.run("/bin/ps", ["-o", "stat=", "-p", pid], timeout: 60)
                return String(decoding: r?.out ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        job.pause()
        // The tool is stopped (SIGSTOP), however long the controller took to notice: its shell writes with a
        // builtin, so every byte it wrote is in the file by then, and nothing more comes while paused.
        await expectEventually("the paused tool was never stopped") { await state().hasPrefix("T") }
        let held = bytes()
        await expectStays(for: 0.2) { bytes() == held }
        job.resume()
        try #require(await eventually { bytes() > held + 2 })
        job.pause()
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        do {
            _ = try await work.value
            Issue.record("Cancelled process returned success")
        } catch FileOperationError.cancelled {} catch { Issue.record("Unexpected error: \(error)") }
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.hasPrefix("started\n"))
        #expect(text.components(separatedBy: "started").count == 2)
        // Thread-local scope cannot cancel an unrelated command on this thread.
        #expect(try Shell.run("/usr/bin/true", []).status == 0)
    }
}
