import Foundation

/// A time-based EWMA (four-second time constant), independent of progress callback frequency.
public struct TransferRate: Sendable {
    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0
    private var expectedRemaining: Int64?
    private var eta: TimeInterval?
    public private(set) var bytesPerSecond: Double = 0
    private let timeConstant: TimeInterval = 4

    public init() {}

    /// Samples use a monotonic clock. Supply totalBytes to also smooth the displayed time-left estimate.
    public mutating func add(bytes: Int64, at time: TimeInterval, totalBytes: Int64? = nil) {
        guard time.isFinite else { return }
        guard let t0 = lastTime else {
            lastTime = time
            lastBytes = max(0, bytes)
            return
        }
        let dt = time - t0
        guard dt >= 0.25 else { return }
        guard bytes >= lastBytes else { reset(); lastTime = time; lastBytes = max(0, bytes); return }
        let instant = Double(bytes - lastBytes) / dt
        let alpha = 1 - exp(-dt / timeConstant)
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond + alpha * (instant - bytesPerSecond)
        lastTime = time
        lastBytes = bytes
        if let totalBytes, totalBytes > 0 {
            let remaining = max(0, totalBytes - bytes)
            expectedRemaining = remaining
            if remaining == 0 {
                eta = 0
            } else if bytesPerSecond > 1 {
                let raw = Double(remaining) / bytesPerSecond
                if let previous = eta {
                    let countdown = max(0, previous - dt)
                    // Trend toward the fresh estimate without jumping by minutes on a single stalled sample.
                    let adjustment = alpha * (raw - countdown)
                    eta = max(0, countdown + max(-2 * dt, min(3 * dt, adjustment)))
                } else {
                    eta = raw
                }
            }
        }
    }

    /// Call after a pause or conflict question: waiting time is not part of transfer speed.
    public mutating func reset() { self = TransferRate() }

    public func secondsLeft(_ remaining: Int64) -> TimeInterval? {
        guard bytesPerSecond > 1 else { return nil }
        if expectedRemaining == max(0, remaining), let eta { return eta }
        return Double(max(0, remaining)) / bytesPerSecond
    }

    public var speedText: String { FileFormat.size(Int64(min(Double(Int64.max / 2), max(0, bytesPerSecond)))) + "/s" }

    public static func leftText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Estimating time left…" }
        let s = Int(min(Double(Int.max / 2), max(0, seconds.rounded())))
        if s < 60 { return s < 5 ? "A few seconds left" : "About \(max(5, ((s + 2) / 5) * 5)) seconds left" }
        if s < 3600 {
            let m = (s + 30) / 60
            return m == 1 ? "About a minute left" : "About \(m) minutes left"
        }
        let h = s / 3600, m = (s % 3600 + 30) / 60
        return m == 0 ? "About \(h) h left" : "About \(h) h \(m) min left"
    }
}
