import Foundation

/// Whether an account counts as offline, from the results of its requests. A flaky network (requests failing and
/// succeeding in turn, as many folders are read at once) shows one steady state instead of a flicker: offline once
/// requests have failed for `showAfter` seconds or `failuresToShow` times in a row, online again once a request got
/// through and none failed for `hideAfter`, and never switching twice within `minInterval`.
public struct OfflineHysteresis: Sendable {
    public private(set) var isOffline = false
    public var showAfter: TimeInterval = 1.5
    public var failuresToShow = 2
    public var hideAfter: TimeInterval = 1
    public var minInterval: TimeInterval = 3
    private var failures = 0
    private var failingSince: Date?
    private var succeedingSince: Date?
    private var lastSwitch = Date.distantPast

    public init() {}

    /// A request's result: `reached` when Drive answered (whatever it answered). True when `isOffline` changed.
    public mutating func record(reached: Bool, at now: Date) -> Bool {
        if reached {
            failures = 0
            failingSince = nil
            if succeedingSince == nil { succeedingSince = now }
        } else {
            failures += 1
            succeedingSince = nil
            if failingSince == nil { failingSince = now }
        }
        return update(at: now)
    }

    /// Looks again as time passes (no request may come to say so). True when `isOffline` changed.
    public mutating func update(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastSwitch) >= minInterval else { return false }
        if isOffline {
            guard let since = succeedingSince, now.timeIntervalSince(since) >= hideAfter else { return false }
        } else {
            guard let since = failingSince, failures >= failuresToShow || now.timeIntervalSince(since) >= showAfter else { return false }
        }
        isOffline.toggle()
        lastSwitch = now
        return true
    }

    /// When `update` may next change the state, if a change is pending.
    public func nextCheck(after now: Date) -> Date? {
        let due = isOffline ? succeedingSince?.addingTimeInterval(hideAfter) : failingSince?.addingTimeInterval(showAfter)
        guard let due else { return nil }
        return max(due, lastSwitch.addingTimeInterval(minInterval), now)
    }
}
