import AppKit
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings)
struct JobResilienceTests {
    @Test func sleepWakeResumesAGigabyteWithoutUndoingAManualPause() async throws {
        let scratch = try Scratch("sleep-job")
        let source = try Self.largeFile(scratch.path("source"), bytes: 1_000_000_000)
        let destination = try scratch.folder("destination")
        let center = NotificationCenter()
        let monitor = JobEnvironmentMonitor(center: center, monitorsNetwork: false)
        let operations = FileOperationsController()
        operations.environment = monitor
        operations.journals = JournalStore(folder: scratch.path("journals"))
        operations.history = OperationHistory(file: scratch.path("history"))
        operations.prepareJob = {
            $0.allowsClone = false; $0.chunkDelay = 0.005; $0.publishInterval = 0
        }
        let ui = ScriptedUI()
        operations.ui = ui
        defer { operations.activities.forEach { $0.control.cancel() } }
        // A busy main actor can receive the first progress after the entire copy has
        // finished. Pause at a worker checkpoint so sleep is tested on an in-flight job.
        let offset: Int64 = try await awaitCallback { ready in
            ui.onJobStarted = { job in
                let original = job.onEvent, control = job.control
                let lock = NSLock()
                var didPause = false
                job.onEvent = { event in
                    original(event)
                    guard case .copied(_, let point) = event, point.offset > 0 else { return }
                    let first = lock.withLock {
                        guard !didPause else { return false }
                        didPause = true
                        return true
                    }
                    guard first else { return }
                    control.pause()
                    ready.resume(returning: point.offset)
                }
            }
            operations.run(.copy, [source], to: destination, window: nil)
        }
        let activity = try #require(operations.activities.first)
        #expect(offset > 0 && offset < 1_000_000_000 && !activity.state.isEnded)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        // Clear only the temporary worker pause: the monitor's sleep hold must now
        // keep it paused independently, before testing the user's own Pause below.
        activity.control.resume()
        #expect(activity.control.isPaused)
        #expect(activity.statusText.contains("Waiting for wake"))
        operations.pause(activity)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(activity.control.isPaused && activity.state == .paused)
        operations.resume(activity)
        try #require(await eventually(120) { activity.state.isEnded })
        #expect(activity.state == .completed && activity.errors.isEmpty)
        let target = destination.appendingPathComponent(source.lastPathComponent)
        let hashes = try await offThePool { (try FileChecksums.digest(source), try FileChecksums.digest(target)) }
        #expect(hashes.0 == hashes.1)
    }

    @Test func networkHoldsOnlyRemoteJobsAndClearWithoutLosingManualPause() {
        let monitor = JobEnvironmentMonitor(center: NotificationCenter(), monitorsNetwork: false)
        let local = JobControl(), remote = JobControl()
        var notice: String?
        monitor.register(local, network: false) { _ in }
        monitor.register(remote, network: true) { notice = $0 }
        monitor.setOnline(false)
        #expect(!local.isPaused && remote.isPaused && notice == "Waiting for network")
        remote.pause()
        monitor.setOnline(true)
        #expect(remote.isPaused && notice == nil)
        remote.resume()
        #expect(!remote.isPaused)
    }

    @Test func cloudTasksUseTheSameNetworkHoldAndAsyncBudget() async throws {
        let scratch = try Scratch("cloud-policy")
        let local = try scratch.file("result", "verified")
        let monitor = JobEnvironmentMonitor(center: NotificationCenter(), monitorsNetwork: false)
        monitor.setOnline(false)
        let operations = FileOperationsController()
        operations.environment = monitor
        operations.history = OperationHistory(file: scratch.path("history"))
        Settings.shared.transferMBPerSecond = 1
        let work = Task {
            try await operations.cloudTask(title: "Copying", sources: [URL(string: "sftp://offline.invalid/result")!]) { context in
                context.progress(500_000, 500_000)
                return [local]
            }
        }
        try #require(await eventually { !operations.activities.isEmpty })
        let activity = try #require(operations.activities.first)
        defer { activity.control.cancel() }
        #expect(activity.statusText.contains("Waiting for network"))
        let start = ProcessInfo.processInfo.systemUptime
        monitor.setOnline(true)
        #expect(try await work.value == [local])
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.49)
        #expect(activity.state == .completed)
    }

    @Test func retriesAreBoundedRecordedAndNeverRetryPermissionFailures() async throws {
        let control = JobControl(policy: .init(retries: 2, backoff: 0.01))
        let result = try await offThePool { () -> Int in
            var attempts = 0
            return try TransferRetry.run(control: control, notice: { _ in }) {
                attempts += 1
                if attempts < 3 { throw URLError(.networkConnectionLost) }
                return attempts
            }
        }
        #expect(result == 3 && control.transferNotes.count == 2)
        #expect(control.transferNotes[0].contains("Retry 1/2, backoff 0.01 s"))
        #expect(control.transferNotes[1].contains("Retry 2/2, backoff 0.02 s"))
        var attempts = 0
        #expect(throws: POSIXError.self) {
            try TransferRetry.run(control: control, notice: { _ in }) {
                attempts += 1; throw POSIXError(.EACCES)
            }
        }
        #expect(attempts == 1)
        let exhausted = JobControl(policy: .init(retries: 0))
        #expect(throws: URLError.self) { try TransferRetry.run(control: exhausted, notice: { _ in }) { throw URLError(.timedOut) } }
        #expect(exhausted.transferNotes.isEmpty)
    }

    @Test func cancellationStopsBackoffWithoutAnotherAttempt() async throws {
        let control = JobControl(policy: .init(retries: 10, backoff: 30))
        let reached = DispatchSemaphore(value: 0)
        let worker = Task {
            try await offThePool {
                try TransferRetry.run(control: control, notice: { _ in reached.signal() }) { throw URLError(.notConnectedToInternet) }
            }
        }
        #expect(await offThePool { reached.wait(timeout: .now() + 60) } == .success)
        control.cancel()
        await #expect(throws: FileOperationError.self) { try await worker.value }
        #expect(control.transferNotes.count == 1)
    }

    @Test(arguments: [FileOperationKind.copy, .move])
    func excludedNestedItemsAreReportedAndNeverMoved(_ kind: FileOperationKind) async throws {
        let scratch = try Scratch("exclusions")
        let source = try scratch.folder("project")
        try scratch.file("project/keep", "keep")
        try scratch.file("project/cache.tmp", "retained")
        try scratch.file("project/.git/objects", "retained too")
        let destination = try scratch.folder("destination")
        let control = JobControl(policy: .init(exclusions: ["*.tmp", ".git"]))
        let job = FileJob(kind: kind, sources: [source], destinationFolder: destination, control: control)
        _ = try await offThePool { try job.run() }
        #expect(job.errors.isEmpty)
        #expect(scratch.read("destination/project/keep") == "keep")
        #expect(scratch.read("destination/project/cache.tmp") == nil)
        #expect(scratch.read("destination/project/.git/objects") == nil)
        #expect(scratch.read("project/cache.tmp") == "retained")
        #expect(scratch.read("project/.git/objects") == "retained too")
        #expect(control.transferNotes.last?.contains("Excluded 2 items") == true)
    }

    @Test func historyPersistsSearchableRetryAndExclusionNotes() throws {
        let scratch = try Scratch("rule-history")
        let history = OperationHistory(file: scratch.path("history"))
        let entry = HistoryEntry(
            date: Date(), operation: "Copy", items: 1, sources: [], destination: nil, bytes: 4, seconds: 1,
            outcome: "Completed", errors: [], transferNotes: ["Retry 1/3, backoff 1.00 s", "Excluded 1 items: *.tmp"])
        history.append(entry); history.flush()
        #expect(history.entries().first?.transferNotes == entry.transferNotes)
        #expect(entry.matches("backoff") && entry.matches("Excluded"))
    }

    @Test(.enabled(if: geteuid() != 0, "needs ordinary file permissions"), arguments: [false, true])
    func administratorFallbackCannotBypassRules(_ limitBandwidth: Bool) async throws {
        let scratch = try Scratch("protected-rules")
        let source = try scratch.file("source", "retained bytes")
        let destination = try scratch.folder("destination")
        #expect(chmod(source.path, 0) == 0)
        defer { chmod(source.path, 0o600) }
        if limitBandwidth { Settings.shared.transferMBPerSecond = 1 } else { Settings.shared.transferExclusions = "*.tmp" }
        let operations = FileOperationsController()
        let ui = ScriptedUI()
        operations.ui = ui
        operations.journals = JournalStore(folder: scratch.path("journals"))
        operations.history = OperationHistory(file: scratch.path("history"))
        operations.prepareJob = { $0.allowsClone = false }
        let result = try await operations.perform(.copy, [source], to: destination)
        #expect(result.isEmpty)
        #expect(operations.activities.first?.state == .failed)
        #expect(operations.activities.first?.errors.contains { $0.contains("transfer rules") } == true)
        #expect(!ui.questions.contains { $0.confirmTitle == "Authenticate" })
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("source").path))
    }

    static func largeFile(_ url: URL, bytes: UInt64, dense: Bool = false) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: Data("first marker".utf8))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if dense {
            try handle.seek(toOffset: 0)
            let block = Data(repeating: 0xa5, count: 1_000_000)
            var left = bytes
            while left > 0 {
                let count = Int(min(UInt64(block.count), left))
                try handle.write(contentsOf: block.prefix(count)); left -= UInt64(count)
            }
        }
        try handle.truncate(atOffset: bytes)
        try handle.seek(toOffset: bytes - 16)
        try handle.write(contentsOf: Data("last marker!!!!!".utf8))
        return url
    }
}
