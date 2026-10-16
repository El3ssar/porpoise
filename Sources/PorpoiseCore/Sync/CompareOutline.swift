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
    public init(_ comparison: SyncComparison) {
        self.comparison = comparison
        var displayRows = comparison.rows
        let indices = Dictionary(displayRows.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for index in displayRows.indices {
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
            let category = CompareFilter.category(row.status)
            counts[category.rawValue, default: 0] += 1
            masks[row.path, default: []].formUnion(category)
        }
        for row in displayRows.reversed() {
            let parent = (row.path as NSString).deletingLastPathComponent
            masks[parent, default: []].formUnion(masks[row.path] ?? [])
        }
        for parent in children.keys {
            children[parent]?.sort {
                let ld = ($0.left ?? $0.right)?.kind == .directory, rd = ($1.left ?? $1.right)?.kind == .directory
                return ld == rd ? $0.path < $1.path : ld
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
                    order = a.path < b.path
                }
                return ascending ? order : !order && a.path != b.path
            }
        }
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
    /// nil means navigation left the linked roots; empty means the root itself. No disk access.
    public static func relativePath(_ url: URL, below root: URL) -> String? {
        guard url.scheme == root.scheme, url.host == root.host, url.user == root.user, url.port == root.port else { return nil }
        let path = url.standardized.pathComponents, base = root.standardized.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return nil }
        return path.dropFirst(base.count).joined(separator: "/")
    }
}
