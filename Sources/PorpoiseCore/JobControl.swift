import Foundation

/// Thread-safe lifecycle shared by local jobs, provider transfers and cloud tasks.
public final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var interrupted = false
    private var ended = false

    public init() {}
    public var isPaused: Bool { condition.withLock { paused } }
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
        while paused && !cancelled && !interrupted { condition.wait() }
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
