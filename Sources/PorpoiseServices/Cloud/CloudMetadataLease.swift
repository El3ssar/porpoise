import Foundation

/// An explicit cache owner/read lifetime. Releasing is idempotent and never waits for provider work or pruning.
final class CloudMetadataLease: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?
    init(generation: UInt64, release: @escaping @Sendable () -> Void) {
        self.generation = generation; onRelease = release
    }
    func release() {
        let callback = lock.withLock {
            defer { onRelease = nil }
            return onRelease
        }
        callback?()
    }
    deinit { release() }
}
