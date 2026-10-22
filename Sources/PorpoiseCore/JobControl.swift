import Foundation

/// Thread-safe lifecycle shared by local jobs, provider transfers and cloud tasks.
public final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var holds: Set<Hold> = []
    public enum Hold: Sendable { case sleep, network }
    private var cancelled = false
    private var interrupted = false
    private var ended = false

    public let policy: TransferPolicy
    private var nextByteTime: TimeInterval = 0
    private var notes: [String] = []
    private var excludedTotal = 0
    private var excludedNames: [String] = []
    private var retriesTotal = 0
    public var excludedCount: Int { condition.withLock { excludedTotal } }
    public init(policy: TransferPolicy = .init()) { self.policy = policy }
    public var transferNotes: [String] {
        condition.withLock {
            (retriesTotal > notes.count ? ["Connection retries: \(retriesTotal) (first 20 below)"] : []) + notes
                + (excludedTotal == 0 ? [] : ["Excluded \(excludedTotal) items: " + excludedNames.joined(separator: ", ")])
        }
    }
    public func recordRetry(_ attempt: Int, delay: TimeInterval) {
        condition.withLock {
            retriesTotal += 1
            if notes.count < 20 { notes.append("Retry \(attempt)/\(policy.retries), backoff \(String(format: "%.2f", delay)) s") }
        }
    }
    public func recordExcluded(_ source: URL) {
        condition.withLock {
            excludedTotal += 1; if excludedNames.count < 5 { excludedNames.append(source.lastPathComponent) }
        }
    }
    private func deadline(for bytes: Int64) -> TimeInterval {
        guard bytes > 0, policy.bytesPerSecond > 0 else { return 0 }
        return condition.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            if nextByteTime == 0 { nextByteTime = now }
            // Carry processing/scheduler time into the next chunk instead of charging it twice.
            // At most 50 ms of credit survives an idle period or a pause.
            nextByteTime = max(now - 0.05, nextByteTime) + Double(bytes) / Double(policy.bytesPerSecond)
            return nextByteTime
        }
    }
    public func throttle(bytes: Int64) throws {
        let end = deadline(for: bytes)
        while end > ProcessInfo.processInfo.systemUptime {
            try checkpoint()
            Thread.sleep(forTimeInterval: min(0.02, max(0, end - ProcessInfo.processInfo.systemUptime)))
        }
        try checkpoint()
    }
    public func throttleAsync(bytes: Int64) async throws {
        let end = deadline(for: bytes)
        while end > ProcessInfo.processInfo.systemUptime {
            try await checkpointAsync()
            try await Task.sleep(for: .seconds(min(0.02, max(0, end - ProcessInfo.processInfo.systemUptime))))
        }
        try await checkpointAsync()
    }
    public var isPaused: Bool { condition.withLock { paused || !holds.isEmpty } }
    public func setHold(_ hold: Hold, active: Bool) {
        condition.withLock {
            if active { holds.insert(hold) } else { holds.remove(hold) }
            condition.broadcast()
        }
    }
    /// Interruption also stops transport work, while retaining its separate outcome for journals.
    public var isCancelled: Bool { condition.withLock { cancelled || interrupted } }
    public var isInterrupted: Bool { condition.withLock { interrupted } }
    public var hasEnded: Bool { condition.withLock { ended } }
    public func pause() { condition.withLock { paused = true } }
    public func resume() {
        condition.withLock {
            paused = false; condition.broadcast()
        }
    }
    public func cancel() {
        condition.withLock {
            cancelled = true; condition.broadcast()
        }
    }
    public func interrupt() {
        condition.withLock {
            interrupted = true; condition.broadcast()
        }
    }
    public func finish() {
        condition.withLock {
            ended = true; condition.broadcast()
        }
    }

    public func waitWhilePaused() {
        condition.lock(); defer { condition.unlock() }
        while (paused || !holds.isEmpty) && !cancelled && !interrupted && !ended { condition.wait() }
    }

    public func checkpoint() throws {
        waitWhilePaused()
        if isInterrupted { throw FileOperationError.interrupted }
        if isCancelled { throw FileOperationError.cancelled }
    }

    /// Async workers never block a cooperative executor while paused.
    public func checkpointAsync() async throws {
        while isPaused && !isCancelled {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        if isInterrupted { throw FileOperationError.interrupted }
        if isCancelled { throw FileOperationError.cancelled }
    }

    public func asDiskCancellation() -> DiskCancellation {
        DiskCancellation(checkpoint: { try self.checkpoint() }, isCancelled: { self.isCancelled })
    }
}
