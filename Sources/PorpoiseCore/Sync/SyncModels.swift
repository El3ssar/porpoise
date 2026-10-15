import Foundation

public enum SyncSide: String, Codable, Sendable {
    case left, right
    public var opposite: SyncSide { self == .left ? .right : .left }
}
public enum SyncEntryKind: String, Codable, Sendable { case file, directory, symlink }

/// Paths are relative, slash separated, and never contain traversal components.
public struct SyncEntry: Codable, Equatable, Sendable {
    public var path: String
    public var kind: SyncEntryKind
    public var size: Int64
    public var modified: Date?
    public var hash: String?
    public var identity: String?
    public var linkTarget: String?
    public init(
        path: String, kind: SyncEntryKind = .file, size: Int64 = 0, modified: Date? = nil,
        hash: String? = nil, identity: String? = nil, linkTarget: String? = nil
    ) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified
        self.hash = hash; self.identity = identity; self.linkTarget = linkTarget
    }
    public static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var entries: [SyncEntry]
    public var caseSensitive: Bool
    /// A depth-limited listing is suitable for browsing, never for destructive planning.
    public var complete: Bool
    public init(entries: [SyncEntry], caseSensitive: Bool = true, complete: Bool = true) {
        self.entries = entries; self.caseSensitive = caseSensitive; self.complete = complete
    }
}
public enum SyncCompareMethod: String, Codable, Sendable { case sizeAndDate, sizeOnly, content }
public struct SyncCompareOptions: Codable, Sendable {
    public var method: SyncCompareMethod
    public var timestampTolerance: TimeInterval
    public var exclusions: [String]
    public init(method: SyncCompareMethod = .sizeAndDate, timestampTolerance: TimeInterval = 2, exclusions: [String] = []) {
        self.method = method; self.timestampTolerance = max(0, timestampTolerance); self.exclusions = exclusions
    }
}
public enum SyncChange: String, Codable, Sendable { case newerLeft, newerRight, unknown }
public enum SyncStatus: Equatable, Sendable { case onlyLeft, onlyRight, changed(SyncChange), same, collision }
public struct SyncDifference: Equatable, Sendable {
    public var path: String
    public var left: SyncEntry?
    public var right: SyncEntry?
    public var status: SyncStatus
}
public struct SyncComparison: Sendable {
    public var rows: [SyncDifference]
    public var complete: Bool
    public var options: SyncCompareOptions
    /// Immediate aligned children; the scanner can separately populate a depth-limited subtree on demand.
    public func children(of path: String = "") -> [SyncDifference] {
        rows.filter { ($0.path as NSString).deletingLastPathComponent == path }
    }
}
public enum SyncMode: String, Codable, Sendable { case backup, mirror, twoWay }
public enum SyncAction: String, Codable, Sendable { case copy, replace, trash, mkdir, conflict }
public enum SyncOverride: String, Codable, Sendable { case skip, keepLeft, keepRight }
public struct SyncStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(action.rawValue):\(target.rawValue):\(path)" }
    public var path: String
    public var sourcePath: String?
    public var source: SyncSide?
    public var target: SyncSide
    public var action: SyncAction
    public var method: SyncCompareMethod = .sizeAndDate
    public var expectedSource: SyncEntry?
    public var expectedTarget: SyncEntry?
    public var reason: String?
    public init(
        path: String, sourcePath: String? = nil, source: SyncSide? = nil, target: SyncSide, action: SyncAction, expectedSource: SyncEntry? = nil,
        expectedTarget: SyncEntry? = nil, reason: String? = nil
    ) {
        self.path = path; self.sourcePath = sourcePath; self.source = source; self.target = target; self.action = action;
        self.expectedSource = expectedSource; self.expectedTarget = expectedTarget; self.reason = reason
    }
}
public struct SyncPlan: Codable, Sendable {
    public var steps: [SyncStep]
    public var conflicts: [SyncStep] { steps.filter { $0.action == .conflict } }
    public init(steps: [SyncStep]) { self.steps = steps }
}
/// Only commit this baseline after a successful run and a fresh comparison. Failed runs retain their old baseline.
public struct SyncState: Codable, Sendable {
    public var version: Int = 1
    public var left: SyncSnapshot
    public var right: SyncSnapshot
    public init(left: SyncSnapshot, right: SyncSnapshot) { self.left = left; self.right = right }
}
