import Darwin
import Foundation

/// Snapshot at enqueue time. Limits apply per job, shared by every transport leg and child worker.
public struct TransferPolicy: Sendable, Equatable {
    public let bytesPerSecond: Int64
    public let retries: Int
    public let backoff: TimeInterval
    public let exclusions: [String]

    public init(bytesPerSecond: Int64 = 0, retries: Int = 3, backoff: TimeInterval = 1, exclusions: [String] = []) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.retries = max(0, min(10, retries))
        self.backoff = backoff.isFinite ? max(0.01, min(30, backoff)) : 1
        self.exclusions = exclusions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public func delay(forRetry attempt: Int) -> TimeInterval { min(30, backoff * pow(2, Double(max(0, min(10, attempt - 1))))) }

    /// Name globs match at any depth. Globs containing '/' match paths relative to the selected item's parent.
    /// '*' can span path separators. Symlinks are never followed to decide exclusions.
    public func excludes(_ url: URL, sources: [URL]) -> Bool {
        guard !exclusions.isEmpty else { return false }
        let root = sources.first { url == $0 || url.path.hasPrefix($0.path + "/") }
        let relative =
            root.map { String(url.path.dropFirst($0.deletingLastPathComponent().path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            ?? url.lastPathComponent
        return exclusions.contains { pattern in
            fnmatch(pattern, pattern.contains("/") ? relative : url.lastPathComponent, 0) == 0
        }
    }
}
