import Foundation

/// Main-thread lookup state. Failures have the same retry interval as successful reads so a status update cannot
/// start a tight failure loop. A later navigation owns the completion; stale workers cannot replace its figure.
struct VolumeCapacityCache {
    typealias Value = (free: Int64, total: Int)
    private var lastAttempt: (url: URL, date: Date)?
    private var stored: (url: URL, value: Value)?
    private var reading: URL?
    private var generation: UInt64 = 0
    static let retryInterval: TimeInterval = 5

    func value(for url: URL) -> Value? { stored.flatMap { $0.url == url ? $0.value : nil } }

    mutating func begin(_ url: URL, at date: Date) -> UInt64? {
        guard url.isFileURL, reading != url else { return nil }
        if let lastAttempt, lastAttempt.url == url, date.timeIntervalSince(lastAttempt.date) < Self.retryInterval { return nil }
        generation &+= 1
        reading = url
        lastAttempt = (url, date)
        return generation
    }

    @discardableResult mutating func finish(_ url: URL, generation expected: UInt64, value: Value?, at date: Date) -> Bool {
        guard reading == url, generation == expected else { return false }
        reading = nil
        lastAttempt = (url, date)
        if let value, value.total > 0 { stored = (url, value) }
        return true
    }
}
