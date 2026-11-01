import Foundation
import PorpoiseCore

/// Immutable detail for compact transfer surfaces. Unknown recursive counts remain nil.
public struct TransferSummary: Sendable {
    public let currentName: String
    /// Processed entries, including skips/reuse. Label these as processed, not newly copied/created.
    public let completedFiles: Int
    public let totalFiles: Int?
    public let completedFolders: Int?
    public let totalFolders: Int?
    public let doneBytes: Int64
    public let totalBytes: Int64
    public let fraction: Double
    public let elapsed: TimeInterval
    public let bytesPerSecond: Double?
    public let speedText: String?
    public let timeLeftText: String?
    public let speedSamples: [TransferSpeedSample]
}

extension Activity {
    public var transferSummary: TransferSummary { transferSummary(at: Date()) }

    public func transferSummary(at date: Date) -> TransferSummary {
        let p = progress
        let measuring = state == .running && p?.phase == .transferring && notice == nil && environmentNotice == nil
        let known = p?.countsAreComplete == true
        return TransferSummary(
            currentName: p?.currentName ?? "", completedFiles: max(0, p?.doneFiles ?? 0),
            totalFiles: known ? p?.totalFiles : nil, completedFolders: known ? p?.doneFolders : nil,
            totalFolders: known ? p?.totalFolders : nil, doneBytes: max(0, p?.doneBytes ?? 0), totalBytes: max(0, p?.totalBytes ?? 0),
            fraction: min(1, max(0, fraction)), elapsed: startedAt.map { max(0, (finishedAt ?? date).timeIntervalSince($0)) } ?? 0,
            bytesPerSecond: measuring && rate.hasSpeedEstimate ? rate.bytesPerSecond : nil,
            speedText: measuring && rate.hasSpeedEstimate ? rate.speedText : nil,
            timeLeftText: measuring ? rate.timeLeftText : nil, speedSamples: speedHistory.samples)
    }
}
