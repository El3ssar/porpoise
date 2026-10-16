import Foundation

public enum TransferEntryKind: String, Codable, Sendable { case file, directory, symlink }

/// Metadata for a single copy source or destination.
public struct TransferEntry: Codable, Equatable, Sendable {
    public var kind: TransferEntryKind
    public var size: Int64
    public var modified: Date?
    public var hash: String?
    public var linkTarget: String?
    public init(
        kind: TransferEntryKind = .file, size: Int64 = 0, modified: Date? = nil,
        hash: String? = nil, linkTarget: String? = nil
    ) {
        self.kind = kind; self.size = size; self.modified = modified
        self.hash = hash; self.linkTarget = linkTarget
    }

}
public enum TransferCompareMethod: String, Codable, Sendable { case sizeAndDate, sizeOnly, content }
public struct TransferCompareOptions: Codable, Equatable, Sendable {
    public var method: TransferCompareMethod
    public var timestampTolerance: TimeInterval
    public init(method: TransferCompareMethod = .sizeAndDate, timestampTolerance: TimeInterval = 2) {
        self.method = method; self.timestampTolerance = max(0, timestampTolerance)
    }
}
public enum TransferChange: String, Codable, Sendable { case newerLeft, newerRight, unknown }
public enum TransferComparisonStatus: Equatable, Sendable { case changed(TransferChange), same }
public enum TransferComparator {
    public static func statusOf(_ left: TransferEntry, _ right: TransferEntry, options: TransferCompareOptions) -> TransferComparisonStatus {
        guard left.kind == right.kind else { return .changed(.unknown) }
        if left.kind == .directory { return .same }
        if left.kind == .symlink { return left.linkTarget != nil && left.linkTarget == right.linkTarget ? .same : .changed(.unknown) }
        var equal = left.size == right.size
        switch options.method {
        case .sizeOnly: break
        case .content: equal = equal && left.hash != nil && left.hash == right.hash
        case .sizeAndDate:
            equal =
                equal && left.modified != nil && right.modified != nil
                && abs((left.modified ?? .distantPast).timeIntervalSince(right.modified ?? .distantFuture)) <= options.timestampTolerance
        }
        if equal { return .same }
        if let l = left.modified, let r = right.modified, abs(l.timeIntervalSince(r)) > options.timestampTolerance {
            return .changed(l > r ? .newerLeft : .newerRight)
        }
        return .changed(.unknown)
    }
}
