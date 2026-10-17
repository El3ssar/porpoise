import Foundation

/// Runs blocking work (a transfer job, a provider's synchronous call) on a thread of its own, as the app does, and
/// waits for it without holding a thread of the cooperative pool. The pool has as many threads as cores (3 on CI's
/// runner); a test blocking one on work that needs another starved the whole run.
public func offThePool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try work() }) }.start()
    }
}

/// `offThePool` for work that can't fail.
public func offThePool<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in Thread { c.resume(returning: work()) }.start() }
}
