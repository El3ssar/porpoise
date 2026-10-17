import Foundation

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
