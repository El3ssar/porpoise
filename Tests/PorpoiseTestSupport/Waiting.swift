import Foundation
import Testing

/// How long a wait for something that must happen gives it by default. Long, because on CI's 3-core runner the whole
/// process can stand still for tens of seconds while other tests hold every core; a wait that comes true returns at
/// once, so only a failing test pays for it.
public let eventualTimeout: TimeInterval = 60

/// Waits up to `timeout` seconds for `condition`, checking every 10 ms on the main actor while the main queue runs (models
/// finish their loads there). Never blocks a thread. True when it came true.
@MainActor
public func eventually(_ timeout: TimeInterval = eventualTimeout, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Waits up to `timeout` seconds for `condition`, by the clock, checking every `every` seconds without blocking a thread.
/// It runs on the caller's actor (a main-actor test's condition reads main-actor state there). True when it came true.
public func poll(
    timeout: TimeInterval = eventualTimeout, every: TimeInterval = 0.01, isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
    }
    return try await condition()
}

/// `poll`, recording an issue at the caller when `condition` doesn't come true within `timeout` seconds (a wait that
/// times out silently lets a test fail later for another reason, or pass when it shouldn't).
public func expectEventually(
    _ comment: Comment? = nil, timeout: TimeInterval = eventualTimeout, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool
) async rethrows {
    if try await poll(timeout: timeout, isolation: isolation, condition) { return }
    Issue.record(comment ?? "Timed out after \(timeout) s", sourceLocation: sourceLocation)
}

/// Checks that `condition` holds for the whole of the next `seconds` (nothing more happens: no bytes while paused, no
/// new results), recording an issue at the caller the first time it doesn't. Named so these windows are easy to find.
public func expectStays(
    for seconds: TimeInterval, _ comment: Comment? = nil, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool
) async rethrows {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        guard try await condition() else {
            Issue.record(comment ?? "Changed within \(seconds) s", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    } while Date() < end
}
