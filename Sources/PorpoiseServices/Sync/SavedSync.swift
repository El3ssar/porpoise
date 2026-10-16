import Foundation
import PorpoiseCore

public enum SyncExclusionPreset: String, Codable, CaseIterable, Sendable {
    case system, hidden, build, versionControl
    public var patterns: [String] {
        switch self {
        case .system: return [".DS_Store", "._*", ".Spotlight-V100", ".Trashes", "Thumbs.db", "desktop.ini", ".porpoise-trash"]
        case .hidden: return [".*"]
        case .build: return ["node_modules", ".build", "build", "DerivedData", "target", ".venv", "__pycache__"]
        case .versionControl: return [".git", ".svn", ".hg"]
        }
    }
}

/// Credentials stay in the existing remote credential store, never in saved sync definitions.
public struct SavedSync: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var left: URL
    public var right: URL
    public var mode: SyncMode
    public var method: SyncCompareMethod = .sizeAndDate
    public var timestampTolerance: TimeInterval = 2
    public var presets: Set<SyncExclusionPreset> = [.system]
    public var customExclusions: [String] = []
    public var visibleInSidebar = true
    public var automatic = false
    public var paused = false
    public var lastSynced: Date?
    public init(id: UUID = UUID(), name: String? = nil, left: URL, right: URL, mode: SyncMode = .backup) {
        self.id = id; self.name = name ?? left.lastPathComponent
        self.left = left; self.right = right; self.mode = mode
    }
    public var options: SyncCompareOptions {
        .init(
            method: method, timestampTolerance: timestampTolerance,
            exclusions: SyncExclusionPreset.allCases.filter { presets.contains($0) }.flatMap(\.patterns) + customExclusions)
    }
    public var leftTitle: String { title(left, other: right) }
    public var rightTitle: String { title(right, other: left) }
    private func title(_ root: URL, other: URL) -> String {
        guard root.lastPathComponent == other.lastPathComponent else { return root.lastPathComponent }
        if root.host != other.host { return root.lastPathComponent + " · " + (root.host ?? "This Mac") }
        let parent = root.deletingLastPathComponent().lastPathComponent
        let otherParent = other.deletingLastPathComponent().lastPathComponent
        return parent != otherParent ? root.lastPathComponent + " · " + parent : root.path
    }
    public var description: String { leftTitle + (mode == .twoWay ? " ⇄ " : " → ") + rightTitle }
}

public actor SavedSyncStore {
    private let file: URL
    private var didReadExisting = false
    private var unsafeToOverwrite = false
    private struct Envelope: Codable { var version = 1; var pairs: [SavedSync] }
    public init(file: URL) { self.file = file }
    public func load() throws -> [SavedSync] {
        didReadExisting = true
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
            guard envelope.version == 1 else { throw SyncEngineError.invalidState }
            try validate(envelope.pairs)
            return envelope.pairs
        } catch { unsafeToOverwrite = true; throw error }
    }
    public func save(_ pairs: [SavedSync]) throws {
        if !didReadExisting { _ = try load() }
        guard !unsafeToOverwrite else { throw SyncEngineError.invalidState }
        try validate(pairs)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Envelope(pairs: pairs)).write(to: file, options: .atomic)
    }
    private func validate(_ pairs: [SavedSync]) throws {
        guard Set(pairs.map(\.id)).count == pairs.count else { throw SyncEngineError.invalidState }
        for pair in pairs {
            guard !pair.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                pair.left.password == nil, pair.right.password == nil,
                pair.left != pair.right,
                pair.left.isFileURL || RemoteFS.provider(for: pair.left) != nil,
                pair.right.isFileURL || RemoteFS.provider(for: pair.right) != nil
            else { throw SyncEngineError.invalidState }
        }
    }
}

public struct SyncPreview: Sendable {
    public var pair: SavedSync
    public var left: SyncSnapshot
    public var right: SyncSnapshot
    public var comparison: SyncComparison
    public var plan: SyncPlan
    public var hasSkippedItems = false
    public var firstTwoWay: Bool
    public init(
        pair: SavedSync, left: SyncSnapshot, right: SyncSnapshot, comparison: SyncComparison,
        plan: SyncPlan, hasSkippedItems: Bool = false, firstTwoWay: Bool
    ) {
        self.pair = pair; self.left = left; self.right = right; self.comparison = comparison
        self.plan = plan; self.hasSkippedItems = hasSkippedItems; self.firstTwoWay = firstTwoWay
    }
    public var skippedConflicts: Int { plan.conflicts.count }
    /// Unresolved conflicts are omitted; dependencies and child protection have already been resolved by the planner.
    public var executable: SyncPlan { .init(steps: plan.steps.filter { $0.action != .conflict }) }
    public var deletionCount: Int { plan.steps.filter { $0.action == .trash }.count }
    public var requiresDeletionReview: Bool {
        [SyncSide.left, .right].contains { side in
            let count = plan.steps.filter { $0.action == .trash && $0.target == side }.count
            let total = side == .left ? left.entries.count : right.entries.count
            return count > 20 && Double(count) > Double(total) * 0.1
        }
    }
}

public enum SyncPreparation {
    /// Call off main. A preview is authoritative only for the exact ordered roots/options that produced it.
    public static func preview(
        _ pair: SavedSync, previous: SyncState? = nil, overrides: [String: SyncOverride] = [:],
        cancellation: DiskCancellation = DiskCancellation()
    ) throws -> SyncPreview {
        let result = try SyncScanner.compare(pair.left, pair.right, options: pair.options, cancellation: cancellation)
        return .init(
            pair: pair, left: result.left, right: result.right, comparison: result.comparison,
            plan: SyncPlanner.plan(result.comparison, mode: pair.mode, previous: previous, overrides: overrides, keepBothLabel: pair.rightTitle),
            hasSkippedItems: overrides.values.contains(.skip), firstTwoWay: pair.mode == .twoWay && previous == nil)
    }
    /// Replanning uses immutable scanned metadata, and does no filesystem IO.
    public static func replan(_ preview: SyncPreview, pair: SavedSync, previous: SyncState?, overrides: [String: SyncOverride]) -> SyncPreview {
        var next = preview
        next.pair = pair
        next.hasSkippedItems = overrides.values.contains(.skip)
        next.plan = SyncPlanner.plan(preview.comparison, mode: pair.mode, previous: previous, overrides: overrides, keepBothLabel: pair.rightTitle)
        next.firstTwoWay = pair.mode == .twoWay && previous == nil
        return next
    }
}
