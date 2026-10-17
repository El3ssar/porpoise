import Foundation
import Testing

/// Waits up to `timeout` seconds for `condition`, checking every 10 ms on the main actor while the main queue runs (models
/// finish their loads there). Never blocks a thread. True when it came true.
@MainActor
public func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
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
    timeout: TimeInterval = 10, every: TimeInterval = 0.01, isolation: isolated (any Actor)? = #isolation,
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
    _ comment: Comment? = nil, timeout: TimeInterval = 10, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool
) async rethrows {
    if try await poll(timeout: timeout, isolation: isolation, condition) { return }
    Issue.record(comment ?? "Timed out after \(timeout) s", sourceLocation: sourceLocation)
}
