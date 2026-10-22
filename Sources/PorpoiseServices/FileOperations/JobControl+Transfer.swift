import Foundation
import PorpoiseCore

extension JobControl {
    func asTransferControl(onBytes: @escaping (Int64) -> Void, onStatus: @escaping (String?) -> Void) -> Shell.TransferControl {
        let transport = Shell.TransferControl(
            isPaused: { self.isPaused }, isCancelled: { self.isCancelled }, isInterrupted: { self.isInterrupted },
            onBytes: onBytes, onStatus: onStatus)
        transport.pace = { try self.throttle(bytes: $0) }
        transport.paceAsync = { try await self.throttleAsync(bytes: $0) }
        transport.managesRetries = true
        transport.bytesPerSecond = policy.bytesPerSecond
        return transport
    }
}

extension Shell {
    /// Every cloud adapter uses the same nonblocking pause and pacing checkpoints.
    static func transferContext() -> CloudTransferContext {
        let control = currentTransferControl
        let bytes = TransferByteBudget()
        return CloudTransferContext(
            checkpoint: {
                while control?.isPaused() == true && control?.isCancelled() != true && control?.isInterrupted() != true {
                    try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20))
                }
                if control?.isInterrupted() == true { throw FileOperationError.interrupted }
                if control?.isCancelled() == true { throw FileOperationError.cancelled }
                try Task.checkCancellation()
                try await control?.paceAsync(bytes.takePending())
            },
            progress: { count, _ in
                let delta = bytes.add(cumulative: count)
                control?.onBytes(delta)
            }, status: { control?.onStatus($0) })
    }

}

final class TransferByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: Int64 = 0
    private var pending: Int64 = 0
    func add(cumulative count: Int64) -> Int64 {
        lock.withLock {
            let delta = max(0, count - previous); previous = count; pending += delta; return delta
        }
    }
    func takePending() -> Int64 {
        lock.withLock {
            let value = pending; pending = 0; return value
        }
    }
}
