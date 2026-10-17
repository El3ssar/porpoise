import Foundation

/// A time-based EWMA (three-second time constant), independent of progress callback frequency.
public struct TransferRate: Sendable {
    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0
    private(set) var eta: TimeInterval?
    public private(set) var bytesPerSecond: Double = 0
    private let timeConstant: TimeInterval = 3
    private var began: TimeInterval?
    private var peak: Double = 0
    private var lowSince: TimeInterval?
    private var lastItems: Int = 0
    private var itemsPerSecond: Double = 0
    private var shownSpeed: Double = 0
    private var speedShownAt: TimeInterval = -.infinity
    private var candidate: Int?
    private var candidateSince: TimeInterval = 0
    private var shownBucket: Int?
    private var lastDecrease: TimeInterval = -.infinity
    private var shownEta = "Estimating time…"
    public var timeLeftText: String {
        if let lowSince, let lastTime, lastTime - lowSince >= 5 { return "Stalled" }
        return shownEta
    }
    public var hasSpeedEstimate: Bool { began.map { (lastTime ?? $0) - $0 >= 1 } ?? false }

    public init() {}

    /// Samples use a monotonic clock. Supply totalBytes to also smooth the displayed time-left estimate.
    public mutating func add(bytes: Int64, at time: TimeInterval, totalBytes: Int64? = nil, items: Int = 0, totalItems: Int? = nil) {
        guard time.isFinite else { return }
        guard let t0 = lastTime else {
            lastTime = time
            began = time
            lastItems = items
            lastBytes = max(0, bytes)
            return
        }
        let dt = time - t0
        guard dt >= 0.25 else { return }
        guard bytes >= lastBytes else { reset(); began = time; lastTime = time; lastBytes = max(0, bytes); lastItems = items; return }
        let instant = Double(bytes - lastBytes) / dt
        let alpha = 1 - exp(-dt / timeConstant)
        let itemInstant = Double(max(0, items - lastItems)) / dt
        itemsPerSecond = itemsPerSecond == 0 ? itemInstant : itemsPerSecond + alpha * (itemInstant - itemsPerSecond)
        lastItems = items
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond + alpha * (instant - bytesPerSecond)
        peak = max(peak, bytesPerSecond)
        if peak > 1 && instant < peak * 0.01 { if lowSince == nil { lowSince = t0 } } else { lowSince = nil }
        if time - speedShownAt >= 1 { shownSpeed = bytesPerSecond; speedShownAt = time }
        lastTime = time
        lastBytes = bytes
        if let totalBytes, totalBytes > 0 {
            let remaining = max(0, totalBytes - bytes)
            if remaining == 0 {
                eta = 0
            } else if bytesPerSecond > 1 {
                let byteEstimate = Double(remaining) / bytesPerSecond
                let itemEstimate = totalItems.map { itemsPerSecond > 0 ? Double(max(0, $0 - items)) / itemsPerSecond : 0 } ?? 0
                let raw = max(byteEstimate, itemEstimate)
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
        updateDisplay(time: time, done: bytes, total: totalBytes, items: items, totalItems: totalItems)
    }

    private mutating func updateDisplay(time: TimeInterval, done: Int64, total: Int64?, items: Int, totalItems: Int?) {
        guard let began, time - began >= 2 else { return }
        let fraction = total.map { $0 > 0 ? Double(done) / Double($0) : 0 } ?? 0
        let itemFraction = totalItems.map { $0 > 0 ? Double(items) / Double($0) : 0 } ?? 0
        guard max(fraction, itemFraction) >= 0.01 else { return }
        let remainingBytes = total.map { max(0, $0 - done) } ?? 0
        let byteTime = bytesPerSecond > 1 ? Double(remainingBytes) / bytesPerSecond : 0
        let itemTime = totalItems.map { itemsPerSecond > 0 ? Double(max(0, $0 - items)) / itemsPerSecond : 0 } ?? 0
        let raw = max(eta ?? byteTime, itemTime)
        guard raw.isFinite else { return }
        let bucket = Self.bucket(raw)
        if candidate != bucket { candidate = bucket; candidateSince = time }
        guard time - candidateSince >= 2 else { return }
        if let shownBucket {
            if bucket > shownBucket && time - lastDecrease < 5 { return }
            if bucket < shownBucket { lastDecrease = time }
        }
        shownBucket = bucket
        shownEta = Self.leftText(Double(bucket))
    }

    /// Call after a pause or conflict question: waiting time is not part of transfer speed.
    public mutating func reset() { self = TransferRate() }

    public var speedText: String {
        FileFormat.speed(hasSpeedEstimate ? shownSpeed : bytesPerSecond)
    }

    private static func bucket(_ seconds: TimeInterval) -> Int {
        let s = Int(min(Double(Int.max / 2), max(0, seconds.rounded())))
        if s < 10 { return 0 }
        if s < 60 { return max(10, ((s + 2) / 5) * 5) }
        if s < 5400 { return max(60, ((s + 30) / 60) * 60) }
        return ((s + 300) / 600) * 600
    }

    public static func leftText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Estimating time left…" }
        let s = bucket(seconds)
        if s < 10 { return "A few seconds left" }
        if s < 60 { return "About \(s) seconds left" }
        if s < 5400 { return "About \(s / 60) \(s / 60 == 1 ? "minute" : "minutes") left" }
        let hours = s / 3600, minutes = (s % 3600) / 60
        let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        return "About " + hourText + (minutes > 0 ? " \(minutes) minutes" : "") + " left"
    }
}
