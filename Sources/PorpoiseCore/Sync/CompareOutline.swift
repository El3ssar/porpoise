import Foundation

public struct CompareFilter: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let onlyLeft = Self(rawValue: 1), onlyRight = Self(rawValue: 2), changed = Self(rawValue: 4), same = Self(rawValue: 8)
    public static let differences: Self = [.onlyLeft, .onlyRight, .changed]
    public static let all: Self = [.differences, .same]
    public static func category(_ status: SyncStatus) -> Self {
        switch status {
        case .onlyLeft: return .onlyLeft;
        case .onlyRight: return .onlyRight;
        case .same: return .same;
        default: return .changed
        }
    }
}

/// Cached tree and descendant filter masks: filtering/expansion does no filesystem work or repeated tree walks.
public struct CompareOutline: Sendable {
    public let comparison: SyncComparison
    public private(set) var children: [String: [SyncDifference]] = [:]
    public private(set) var masks: [String: CompareFilter] = [:]
    public private(set) var counts: [Int: Int] = [:]
    public private(set) var differenceCounts: [String: Int] = [:]
    public private(set) var childCounts: [SyncSide: [String: Int]] = [:]
    public private(set) var totalBytes: [SyncSide: Int64] = [:]
    public init(_ comparison: SyncComparison) {
        self.comparison = comparison
        var displayRows = comparison.rows
        if !comparison.caseSensitive {
            // An only-right child may use a different spelling of its aligned parent. Give the
            // presentation one parent path while retaining each entry's actual filesystem path.
            var canonical: [String: String] = [:]
            for index in displayRows.indices {
                let path = displayRows[index].path, parent = (path as NSString).deletingLastPathComponent
                if let aligned = canonical[parent.precomposedStringWithCanonicalMapping.lowercased()] {
                    displayRows[index].path = aligned + "/" + (path as NSString).lastPathComponent
                }
                canonical[path.precomposedStringWithCanonicalMapping.lowercased()] = displayRows[index].path
            }
        }
        let indices = Dictionary(displayRows.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for index in displayRows.indices {
            if !comparison.complete, (displayRows[index].left ?? displayRows[index].right)?.kind == .directory,
                displayRows[index].status == .same
            {
                displayRows[index].status = .changed(.unknown)
            }
            if let left = displayRows[index].left, let right = displayRows[index].right,
                (left.path as NSString).lastPathComponent != (right.path as NSString).lastPathComponent,
                displayRows[index].status == .same
            {
                displayRows[index].status = .changed(.unknown)
            }
        }
        for row in displayRows.reversed() where row.status != .same {
            let parent = (row.path as NSString).deletingLastPathComponent
            if let index = indices[parent], displayRows[index].status == .same { displayRows[index].status = .changed(.unknown) }
        }
        for row in displayRows {
            children[(row.path as NSString).deletingLastPathComponent, default: []].append(row)
            for side in [SyncSide.left, .right] where (side == .left ? row.left : row.right) != nil {
                childCounts[side, default: [:]][(row.path as NSString).deletingLastPathComponent, default: 0] += 1
                if let entry = side == .left ? row.left : row.right, entry.kind == .file { totalBytes[side, default: 0] += entry.size }
            }
            let category = CompareFilter.category(row.status)
            counts[category.rawValue, default: 0] += 1
            let rollup =
                row.left?.kind == .directory && row.right?.kind == .directory
                && row.status == .changed(.unknown) && comparison.complete
                && (row.left!.path as NSString).lastPathComponent == (row.right!.path as NSString).lastPathComponent
            // A folder's aggregate Changed status is not itself a Changed descendant. Its mask
            // comes from matching children, so an Only-only subtree disappears under Changed-only.
            if !rollup { masks[row.path, default: []].formUnion(category) }
            differenceCounts[row.path] = (row.left ?? row.right)?.kind != .directory && row.status != .same ? 1 : 0
        }
        for row in displayRows.reversed() {
            let parent = (row.path as NSString).deletingLastPathComponent
            masks[parent, default: []].formUnion(masks[row.path] ?? [])
            differenceCounts[parent, default: 0] += differenceCounts[row.path] ?? 0
        }
        for parent in children.keys {
            children[parent]?.sort {
                let ld = ($0.left ?? $0.right)?.kind == .directory, rd = ($1.left ?? $1.right)?.kind == .directory
                return ld == rd ? Self.nameOrder($0.path, $1.path) : ld
            }
        }
    }
    public func visible(filter: CompareFilter, expanded: Set<String>) -> [SyncDifference] {
        var result: [SyncDifference] = []
        func append(_ parent: String) {
            for row in children[parent] ?? [] where !(masks[row.path] ?? []).intersection(filter).isEmpty {
                result.append(row)
                if expanded.contains(row.path) { append(row.path) }
            }
        }
        append(""); return result
    }
    public mutating func sort(by role: ItemRole, side: SyncSide, ascending: Bool) {
        for parent in children.keys {
            children[parent]?.sort { a, b in
                let l = (side == .left ? a.left : a.right) ?? a.left ?? a.right
                let r = (side == .left ? b.left : b.right) ?? b.left ?? b.right
                if (l?.kind == .directory) != (r?.kind == .directory) { return l?.kind == .directory }
                let order: Bool
                if role == .size, l?.size != r?.size {
                    order = (l?.size ?? 0) < (r?.size ?? 0)
                } else if role == .modificationTime, l?.modified != r?.modified {
                    order = (l?.modified ?? .distantPast) < (r?.modified ?? .distantPast)
                } else {
                    order = Self.nameOrder(a.path, b.path)
                }
                return ascending ? order : !order && a.path != b.path
            }
        }
    }
    private static func nameOrder(_ left: String, _ right: String) -> Bool {
        let order = left.localizedStandardCompare(right)
        return order == .orderedSame ? left < right : order == .orderedAscending
    }
    public static func sideNames(_ left: URL, _ right: URL) -> (String, String) {
        var l = left.lastPathComponent, r = right.lastPathComponent
        if l == r {
            if left.host != right.host {
                if let host = left.host { l = host }; if let host = right.host { r = host }
            } else {
                for ancestor in right.pathComponents.dropLast().reversed() where ancestor != l && ancestor != "/" && !ancestor.isEmpty {
                    r = ancestor; break
                }
                if l == r && left != right { r = right.path }
            }
        }
        return (l.isEmpty ? "/" : l, r.isEmpty ? "/" : r)
    }
}

public enum LinkedBrowsing {
    /// Follow a descendant relative to the anchors, or mirror an upward step beyond them.
    /// Unrelated path edits establish a fresh anchor pair instead of jumping to an arbitrary folder.
    public static func counterpart(_ url: URL, sourceRoot: URL, targetRoot: URL) -> URL? {
        if let relative = relativePath(url, below: sourceRoot) {
            return relative.isEmpty ? targetRoot : targetRoot.appendingPathComponent(relative)
        }
        guard let relative = relativePath(sourceRoot, below: url), !relative.isEmpty else { return nil }
        var target = targetRoot
        for _ in relative.split(separator: "/") {
            guard target.path != "/" else { return nil }
            target.deleteLastPathComponent()
        }
        return target
    }
    /// nil means navigation left the linked roots; empty means the root itself. No disk access.
    public static func relativePath(_ url: URL, below root: URL) -> String? {
        guard url.scheme == root.scheme, url.host == root.host, url.user == root.user, url.port == root.port else { return nil }
        let path = url.standardized.pathComponents, base = root.standardized.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return nil }
        return path.dropFirst(base.count).joined(separator: "/")
    }
}
