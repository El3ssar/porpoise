import Foundation

public enum SyncPlanner {
    public static func plan(
        _ comparison: SyncComparison, mode: SyncMode, previous: SyncState? = nil,
        overrides: [String: SyncOverride] = [:]
    ) -> SyncPlan {
        guard comparison.complete else {
            return .init(steps: [.init(path: "", target: .right, action: .conflict, reason: "Finish scanning both folders before syncing.")])
        }
        let oldLeft = Dictionary(previous?.left.entries.map { ($0.path, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let oldRight = Dictionary(previous?.right.entries.map { ($0.path, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var steps: [SyncStep] = []
        var blocked: [String] = []
        for row in comparison.rows {
            if blocked.contains(where: { row.path.hasPrefix($0 + "/") }) { continue }
            let choice = overrides[row.path]
            if choice == .skip { blocked.append(row.path); continue }
            var step: SyncStep?
            if row.status == .collision {
                step = conflict(row, "Names collide on a case-insensitive destination.")
            } else if let l = row.left, let r = row.right, l.kind != r.kind {
                step = conflict(row, "A folder, file, or link occupies the other side; resolve the type conflict first.")
            } else if choice == .keepLeft {
                step = transfer(row, from: .left)
            } else if choice == .keepRight {
                step = transfer(row, from: .right)
            } else if mode == .twoWay {
                step = twoWay(
                    row, oldLeft: oldLeft[row.left?.path ?? row.path], oldRight: oldRight[row.right?.path ?? row.path],
                    hasState: previous != nil, options: comparison.options)
            } else {
                switch row.status {
                case .onlyLeft: step = transfer(row, from: .left)
                case .onlyRight: if mode == .mirror { step = trash(row, side: .right) }
                case .changed:
                    // Folder timestamps and roll-ups do not themselves require copying a folder tree.
                    if row.left?.kind != .directory { step = transfer(row, from: .left) }
                case .same, .collision: break
                }
            }
            if var step {
                if step.action == .trash, (step.target == .left ? row.left : row.right)?.kind == .directory,
                    !comparison.options.exclusions.isEmpty
                {
                    step = conflict(row, "Folder deletion could contain excluded items; review it separately.")
                }
                step.method = comparison.options.method
                steps.append(step)
                if step.action == .conflict { blocked.append(row.path) }
            }
        }
        // A directory may only disappear when every visible descendant is also being removed.
        let protected = blocked + steps.filter { $0.action != .trash && $0.action != .mkdir }.map(\.path)
        steps.removeAll { step in
            step.action == .trash && step.expectedTarget?.kind == .directory
                && protected.contains { $0.hasPrefix(step.path + "/") }
        }
        // Parents first for creation; leaves first for removal. Every leaf remains explicit in the preview.
        return .init(
            steps: steps.sorted { a, b in
                if (a.action == .trash) != (b.action == .trash) { return b.action == .trash }
                if a.action == .trash { return a.path > b.path }
                return a.path < b.path
            })
    }
    private static func twoWay(
        _ row: SyncDifference, oldLeft: SyncEntry?, oldRight: SyncEntry?, hasState: Bool,
        options: SyncCompareOptions
    ) -> SyncStep? {
        if let l = row.left, let r = row.right {
            if l.kind == .directory && r.kind == .directory { return nil }
            if SyncComparator.statusOf(l, r, options: options) == .same { return nil }
            guard hasState else { return conflict(row, "Both sides differ on the first sync.") }
            let lc = changed(l, oldLeft), rc = changed(r, oldRight)
            if lc && !rc { return transfer(row, from: .left) }
            if rc && !lc { return transfer(row, from: .right) }
            return conflict(row, "Both sides changed, or there is no common baseline.")
        }
        let side: SyncSide = row.left != nil ? .left : .right
        let current = row.left ?? row.right!
        let oldHere = side == .left ? oldLeft : oldRight
        let oldThere = side == .left ? oldRight : oldLeft
        if hasState && oldThere != nil {
            if !changed(current, oldHere) { return trash(row, side: side) }
            return conflict(row, "One side was deleted while the other changed.")
        }
        return transfer(row, from: side)
    }
    private static func changed(_ current: SyncEntry, _ old: SyncEntry?) -> Bool {
        guard let old else { return true }
        if current.kind != old.kind || current.linkTarget != old.linkTarget { return true }
        if current.kind == .directory { return false }
        if let a = current.hash, let b = old.hash { return a != b }
        return current.size != old.size || current.modified != old.modified || current.identity != old.identity
    }
    private static func transfer(_ row: SyncDifference, from source: SyncSide) -> SyncStep? {
        guard let entry = source == .left ? row.left : row.right else { return nil }
        let target = source == .left ? row.right : row.left
        if target?.kind == .directory && entry.kind == .directory { return nil }
        return .init(
            path: target?.path ?? entry.path, sourcePath: entry.path, source: source, target: source.opposite,
            action: entry.kind == .directory ? .mkdir : (target == nil ? .copy : .replace), expectedSource: entry, expectedTarget: target)
    }
    private static func trash(_ row: SyncDifference, side: SyncSide) -> SyncStep {
        .init(
            path: (side == .left ? row.left : row.right)?.path ?? row.path, target: side, action: .trash,
            expectedTarget: side == .left ? row.left : row.right)
    }
    private static func conflict(_ row: SyncDifference, _ reason: String) -> SyncStep {
        .init(path: row.path, target: .right, action: .conflict, reason: reason)
    }
}
