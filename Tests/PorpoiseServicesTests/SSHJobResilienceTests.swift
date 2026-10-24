import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Scratch-only localhost sshd with isolated keys. Never accesses an external account.
@MainActor @Suite(.serialized, .isolatedSettings, .enabled(if: SSHServer.isAvailable, "needs localhost sshd"), .sshServer)
struct SSHJobResilienceTests {
    let server = SSHServer.current!

    @Test func aDroppedServerReturnsAndCompletesTheSameGigabyte() async throws {
        let scratch = try Scratch("network-job")
        let folder = try server.folder()
        let source = try JobResilienceTests.largeFile(folder.appendingPathComponent("source"), bytes: 1_000_000_000, dense: true)
        let remote = server.url(source)
        RemoteFS.use(server.provider(), for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        let monitor = JobEnvironmentMonitor(monitorsNetwork: false)
        let operations = FileOperationsController()
        operations.environment = monitor
        operations.history = OperationHistory(file: scratch.path("history"))
        Settings.shared.transferMBPerSecond = 100
        Settings.shared.transferRetries = 3
        Settings.shared.transferBackoffSeconds = 0.05
        operations.run(.copy, [remote], to: scratch.url, window: nil)
        let activity = try #require(operations.activities.first)
        #expect(activity.control.policy.bytesPerSecond == 100_000_000)
        defer { activity.control.cancel() }
        try #require(await eventually { (activity.progress?.doneBytes ?? 0) >= 4_000_000 })
        monitor.setOnline(false)
        #expect(activity.statusText.contains("Waiting for network"))
        #expect(activity.state != .failed && activity.control.isPaused)
        try await offThePool {
            // Kill the scratch listener's entire existing process tree, including modern OpenSSH's
            // session grandchildren; killing only its immediate child can leave an active stream alive.
            let listener = try #require(Int((server.scratch.read("sshd.pid") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            let rows = try Shell.run("/bin/ps", ["-axo", "pid=,ppid="])
            let pairs = String(decoding: rows.out, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
                let values = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                return values.count == 2 ? (values[0], values[1]) : nil
            }
            var owned: Set<Int32> = [Int32(listener)]
            while true {
                let children = Set(pairs.filter { owned.contains($0.1) }.map(\.0))
                if children.isSubset(of: owned) { break }; owned.formUnion(children)
            }
            for pid in owned where pid != Int32(listener) { kill(pid, SIGKILL) }
            server.killAbruptly()
        }
        // Pause holds independently of transport failure; the failed stage is retried after reconnect.
        try await offThePool { try server.start() }
        monitor.setOnline(true)
        try #require(await eventually(120) { activity.state.isEnded })
        #expect(activity.state == .completed && activity.errors.isEmpty)
        let target = scratch.path("source")
        let hashes = try await offThePool { (try FileChecksums.digest(source), try FileChecksums.digest(target)) }
        #expect(hashes.0 == hashes.1)
        #expect(activity.control.transferNotes.contains { $0.contains("Retry") })
        #expect(operations.history.entries().first?.transferNotes?.contains { $0.contains("backoff") } == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_BENCHMARK"] == "1", "opt-in 30-second bandwidth measurement"))
    func fiftyMBPerSecondForThirtySeconds() async throws {
        let scratch = try Scratch("bandwidth-job")
        let folder = try server.folder()
        let source = try JobResilienceTests.largeFile(folder.appendingPathComponent("payload"), bytes: 1_500_000_000, dense: true)
        let provider = server.provider()
        let remote = server.url(source)
        let control = JobControl(policy: .init(bytesPerSecond: 50_000_000, retries: 0))
        let result = try await offThePool { () -> (URL, Double) in
            let transport = control.asTransferControl(onBytes: { _ in }, onStatus: { _ in })
            let start = ProcessInfo.processInfo.systemUptime
            let target = try Shell.withTransferControl(transport) { try provider.download(remote, into: scratch.url) }
            return (target, ProcessInfo.processInfo.systemUptime - start)
        }
        let rate = 1_500_000_000 / result.1
        print("TRANSFER_CAP bytes=1500000000 seconds=\(result.1) MB_per_second=\(rate / 1_000_000) limit_MB_per_second=50")
        #expect(result.1 >= 30)
        #expect(rate >= 45_000_000 && rate <= 55_000_000)
        let hashes = try await offThePool { (try FileChecksums.digest(source), try FileChecksums.digest(result.0)) }
        #expect(hashes.0 == hashes.1)
    }
}
