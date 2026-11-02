import Foundation

public struct TransferSpeedSample: Equatable, Sendable {
    public let elapsed: TimeInterval
    public let bytesPerSecond: Double
    /// A pause or a conflict starts a new segment; charts should not connect across it.
    public let segment: Int
}

/// A bounded graph of transfer throughput, sampled by existing progress callbacks, never a timer.
public struct TransferSpeedHistory: Sendable {
    public static let capacity = 120
    public private(set) var samples: [TransferSpeedSample] = []
    private var origin: TimeInterval?
    private var baseline: (time: TimeInterval, bytes: Int64)?
    private var segment = 0

    public init() {}

    /// Anchor the graph to job start, including any preparation time before byte progress arrives.
    public mutating func begin(at time: TimeInterval) {
        if origin == nil && time.isFinite { origin = time }
    }

    public mutating func interrupt() {
        baseline = nil
        segment += 1
    }

    public mutating func add(bytes: Int64, at time: TimeInterval) {
        guard time.isFinite else { return }
        if origin == nil { origin = time }
        let bytes = max(0, bytes)
        guard let previous = baseline else { baseline = (time, bytes); return }
        guard time >= previous.time else { return }
        guard bytes >= previous.bytes else {
            interrupt(); baseline = (time, bytes); return
        }
        let duration = time - previous.time
        guard duration >= 0.5 else { return }
        samples.append(
            TransferSpeedSample(elapsed: max(0, time - (origin ?? time)), bytesPerSecond: Double(bytes - previous.bytes) / duration, segment: segment)
        )
        if samples.count > Self.capacity {
            // Keep the beginning and newest point, retaining representative measured points across the
            // whole job. Segment identities survive thinning, so a chart never bridges a paused interval.
            let last = samples.count - 1
            samples = samples.indices.compactMap { index in
                index == 0 || index == last || index.isMultiple(of: 2) ? samples[index] : nil
            }
        }
        baseline = (time, bytes)
    }
}
