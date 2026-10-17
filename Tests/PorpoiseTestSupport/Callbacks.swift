import Foundation
import Testing

/// A callback that never came, after `awaitCallback`'s timeout (the issue is already recorded).
public struct CallbackTimedOut: Error {}

/// What `awaitCallback` hands to the API under test: its answer goes through `resume`, once (a second answer, or one
/// after the timeout, is ignored). Spelled like a continuation's, so a callback test reads the same.
public final class Callback<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: ((Result<T, Error>) -> Void)?
    fileprivate init(_ deliver: @escaping (Result<T, Error>) -> Void) { self.deliver = deliver }

    public func resume(returning value: T) { finish(.success(value)) }
    public func resume(throwing error: Error) { finish(.failure(error)) }
    public func resume(with result: Result<T, Error>) { finish(result) }

    fileprivate func finish(_ result: Result<T, Error>) {
        let deliver = lock.withLock {
            defer { self.deliver = nil }
            return self.deliver
        }
        deliver?(result)
    }
}

extension Callback where T == Void {
    public func resume() { resume(returning: ()) }
}

/// Waits for a callback API's answer: `start` calls it, handing it `callback`. A callback that never comes records an
/// issue at the caller after `timeout` seconds and throws `CallbackTimedOut`, instead of hanging the whole run until
/// the watchdog kills it (one hang hides every other result).
public func awaitCallback<T>(
    _ comment: Comment? = nil, timeout: TimeInterval = 60, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation, _ start: (Callback<T>) throws -> Void
) async throws -> T {
    do {
        return try await withCheckedThrowingContinuation(isolation: isolation) { (c: CheckedContinuation<T, Error>) in
            let callback = Callback<T> { c.resume(with: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { callback.finish(.failure(CallbackTimedOut())) }
            do { try start(callback) } catch { callback.resume(throwing: error) }
        }
    } catch let error as CallbackTimedOut {
        Issue.record(comment ?? "No callback within \(Int(timeout)) seconds", sourceLocation: sourceLocation)
        throw error
    }
}
