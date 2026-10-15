import Darwin
import Foundation

public enum SyncComparator {
    public static func excluded(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let components = path.split(separator: "/").map(String.init)
        var ancestors: [String] = []; var prefix = ""
        for component in components { prefix = prefix.isEmpty ? component : prefix + "/" + component; ancestors.append(prefix) }
        return patterns.contains { pattern in
            let glob = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
            return ancestors.contains { candidate in
                fnmatch(glob, candidate, 0) == 0 || (!glob.contains("/") && fnmatch(glob, (candidate as NSString).lastPathComponent, 0) == 0)
            }
        }
    }
    public static func compare(_ left: SyncSnapshot, _ right: SyncSnapshot, options: SyncCompareOptions = .init()) -> SyncComparison {
        let sensitive = left.caseSensitive && right.caseSensitive
        func key(_ path: String) -> String { sensitive ? path : path.precomposedStringWithCanonicalMapping.lowercased() }
        func grouped(_ snapshot: SyncSnapshot) -> [String: [SyncEntry]] {
            Dictionary(grouping: snapshot.entries.filter { !excluded($0.path, patterns: options.exclusions) }, by: { key($0.path) })
        }
        let lhs = grouped(left), rhs = grouped(right)
        var rows: [SyncDifference] = []
        rows.reserveCapacity(max(lhs.count, rhs.count))
        for name in Set(lhs.keys).union(rhs.keys).sorted() {
            let ls = lhs[name] ?? [], rs = rhs[name] ?? []
            let l = ls.first, r = rs.first
            let status: SyncStatus
            if ls.count > 1 || rs.count > 1 || !SyncEntry.isSafePath(l?.path ?? r?.path ?? "") {
                status = .collision
            } else if let l, let r {
                status = statusOf(l, r, options: options)
            } else {
                status = l == nil ? .onlyRight : .onlyLeft
            }
            rows.append(.init(path: l?.path ?? r!.path, left: l, right: r, status: status))
        }
        // Roll up children without repeatedly walking the tree. Descendants always sort after their parent.
        var indices: [String: Int] = [:]
        for (index, row) in rows.enumerated() { indices[key(row.path)] = index }
        for index in rows.indices.reversed() where rows[index].status != .same {
            let parent = (rows[index].path as NSString).deletingLastPathComponent
            if let p = indices[key(parent)], rows[p].status == .same { rows[p].status = .changed(.unknown) }
        }
        return .init(
            rows: rows, caseSensitive: sensitive, leftRootIdentity: left.rootIdentity, rightRootIdentity: right.rootIdentity,
            complete: left.complete && right.complete, options: options)
    }
    public static func statusOf(_ left: SyncEntry, _ right: SyncEntry, options: SyncCompareOptions) -> SyncStatus {
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
