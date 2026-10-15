import Foundation

/// The speed of a transfer from its progress samples (smoothed over the last few seconds), and the time left.
public struct TransferRate: Sendable {
    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0
    /// Bytes per second, smoothed.
    public private(set) var bytesPerSecond: Double = 0
    /// How much a new second counts against the smoothed speed.
    private let smoothing = 0.3

    public init() {}

    /// Takes the bytes done so far at `time` (seconds, any monotonic origin). A pause shows as no progress.
    public mutating func add(bytes: Int64, at time: TimeInterval) {
        guard let t0 = lastTime else {
            lastTime = time
            lastBytes = bytes
            return
        }
        let dt = time - t0
        guard dt >= 0.25 else { return }  // too close together to say much
        let instant = Double(max(0, bytes - lastBytes)) / dt
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond + min(1, smoothing * dt) * (instant - bytesPerSecond)
        lastTime = time
        lastBytes = bytes
    }

    /// Forgets the speed (after a pause, so the estimate doesn't count the wait).
    public mutating func reset() { self = TransferRate() }

    /// Seconds left for `remaining` bytes at the current speed; nil until there is a speed.
    public func secondsLeft(_ remaining: Int64) -> TimeInterval? {
        bytesPerSecond > 1 ? Double(max(0, remaining)) / bytesPerSecond : nil
    }

    /// "12.3 MB/s"
    public var speedText: String { FileFormat.size(Int64(bytesPerSecond)) + "/s" }

    /// "About 3 minutes left", "Less than a minute left".
    public static func leftText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return s < 5 ? "A few seconds left" : "\(s) seconds left" }
        if s < 3600 {
            let m = (s + 30) / 60
            return m == 1 ? "About a minute left" : "About \(m) minutes left"
        }
        let h = s / 3600, m = (s % 3600 + 30) / 60
        return m == 0 ? "About \(h) h left" : "About \(h) h \(m) min left"
    }
}
