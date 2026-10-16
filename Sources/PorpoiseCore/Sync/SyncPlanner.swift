import Foundation

public enum SyncPlanner {
    public static func plan(
        _ comparison: SyncComparison, mode: SyncMode, previous: SyncState? = nil,
        overrides: [String: SyncOverride] = [:], keepBothLabel: String = "right"
    ) -> SyncPlan {
        guard comparison.complete, previous == nil || (previous!.version == 1 && previous!.left.complete && previous!.right.complete) else {
            return .init(steps: [.init(path: "", target: .right, action: .conflict, reason: "Finish scanning both folders before syncing.")])
        }
        if let previous,
            (previous.left.rootIdentity != nil && previous.left.rootIdentity != comparison.leftRootIdentity)
                || (previous.right.rootIdentity != nil && previous.right.rootIdentity != comparison.rightRootIdentity)
        {
            return .init(steps: [
                .init(
                    path: "", target: .right, action: .conflict,
                    reason: "A folder or mounted volume changed identity. Reconnect it and compare again.")
            ])
        }
        let label = keepBothLabel.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        let safeLabel = label.isEmpty || label == "." || label == ".." ? "right" : label
        func key(_ path: String) -> String { comparison.caseSensitive ? path : path.precomposedStringWithCanonicalMapping.lowercased() }
        let oldLeft = Dictionary(previous?.left.entries.map { (key($0.path), $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let oldRight = Dictionary(previous?.right.entries.map { (key($0.path), $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var steps: [SyncStep] = []
        var blocked: [String] = []
        let knownEntries = Dictionary(grouping: comparison.rows.flatMap { [$0.left, $0.right].compactMap { $0 } }, by: { $0.path.lowercased() })
        var occupied = Set(comparison.rows.flatMap { [$0.left?.path, $0.right?.path].compactMap { $0?.lowercased() } })
        for row in comparison.rows {
            if blocked.contains(where: { key(row.path).hasPrefix(key($0) + "/") }) { continue }
            let choice = overrides[row.path]
            if choice == .skip { blocked.append(row.path); continue }
            var step: SyncStep?
            if row.status == .collision {
                step = conflict(row, "Names collide on a case-insensitive destination.")
            } else if let l = row.left, let r = row.right, l.kind != r.kind {
                step = conflict(row, "A folder, file, or link occupies the other side; resolve the type conflict first.")
            } else if choice == .trash {
                // Explicitly reviewed delete-versus-edit choice: only a single present leaf may be trashed.
                // A missing source never silently turns Keep Left/Right into a deletion.
                if mode == .twoWay, oldLeft[key(row.path)] != nil, oldRight[key(row.path)] != nil, (row.left == nil) != (row.right == nil),
                    let present = row.left ?? row.right, present.kind != .directory
                {
                    step = trash(row, side: row.left == nil ? .right : .left)
                } else {
                    step = conflict(row, "Review this folder or type conflict separately before deleting.")
                }
            } else if choice == .keepBoth, let left = row.left, let right = row.right, left.kind != .directory {
                if row.status == .same { continue }
                let base = (right.path as NSString).deletingPathExtension
                let ext = (right.path as NSString).pathExtension
                var number = 1, name = ""
                repeat {
                    name = base + " (" + safeLabel + (number == 1 ? "" : " \(number)") + ")" + (ext.isEmpty ? "" : "." + ext)
                    number += 1
                    if let existing = knownEntries[name.lowercased()], !existing.isEmpty,
                        existing.allSatisfy({ SyncComparator.statusOf($0, right, options: comparison.options) == .same })
                    {
                        break
                    }
                } while occupied.contains(name.lowercased())
                occupied.insert(name.lowercased())
                let copies = [SyncSide.left, .right].map { side -> SyncStep in
                    var copy = SyncStep(
                        path: name, sourcePath: right.path, source: .right, target: side,
                        action: .copy, expectedSource: right)
                    copy.method = comparison.options.method
                    copy.timestampTolerance = comparison.options.timestampTolerance
                    return copy
                }
                steps.append(contentsOf: copies)
                step = transfer(row, from: .left)
                step?.dependsOn = copies.map(\.id)
            } else if choice == .keepLeft {
                step =
                    row.left == nil
                    ? conflict(row, "The selected side no longer has this item. Choose Keep or Move to Trash.") : transfer(row, from: .left)
            } else if choice == .keepRight {
                step =
                    row.right == nil
                    ? conflict(row, "The selected side no longer has this item. Choose Keep or Move to Trash.") : transfer(row, from: .right)
            } else if mode == .twoWay {
                step = twoWay(
                    row, oldLeft: oldLeft[key(row.left?.path ?? row.path)], oldRight: oldRight[key(row.right?.path ?? row.path)],
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
                if step.action == .trash, (step.target == .left ? row.left : row.right)?.kind == .directory {
                    let excluded = step.target == .left ? comparison.leftExcludedPaths : comparison.rightExcludedPaths
                    let containsExcluded =
                        excluded?.contains { key($0) == key(row.path) || key($0).hasPrefix(key(row.path) + "/") } ?? !comparison.options.exclusions
                        .isEmpty
                    if containsExcluded { step = conflict(row, "Folder deletion could contain excluded items; review it separately.") }
                }
                step.method = comparison.options.method
                step.timestampTolerance = comparison.options.timestampTolerance
                steps.append(step)
                if step.action == .conflict { blocked.append(row.path) }
            }
        }
        for index in steps.indices {
            steps[index].leftRootIdentity = comparison.leftRootIdentity
            steps[index].rightRootIdentity = comparison.rightRootIdentity
        }
        // Preserve the destination's spelling for aligned case-insensitive parent folders.
        let leftPaths = Dictionary(comparison.rows.compactMap { $0.left }.map { (key($0.path), $0.path) }, uniquingKeysWith: { a, _ in a })
        let rightPaths = Dictionary(comparison.rows.compactMap { $0.right }.map { (key($0.path), $0.path) }, uniquingKeysWith: { a, _ in a })
        var remappedIDs: [String: String] = [:]
        for index in steps.indices where steps[index].expectedTarget == nil {
            let oldID = steps[index].id
            let paths = steps[index].target == .left ? leftPaths : rightPaths
            var parent = (steps[index].path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let spelling = paths[key(parent)] {
                    steps[index].path = spelling + String(steps[index].path.dropFirst(parent.count)); break
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            remappedIDs[oldID] = steps[index].id
        }
        for index in steps.indices { steps[index].dependsOn = steps[index].dependsOn.map { remappedIDs[$0] ?? $0 } }
        // A directory may only disappear when every visible descendant is also being removed.
        let protected = blocked + steps.filter { $0.action != .trash && $0.action != .mkdir }.map(\.path)
        steps.removeAll { step in
            step.action == .trash && step.expectedTarget?.kind == .directory
                && protected.contains { key($0).hasPrefix(key(step.path) + "/") }
        }
        // Parents first for creation; leaves first for removal. Every leaf remains explicit in the preview.
        let sorted = steps.sorted { a, b in
            if (a.action == .trash) != (b.action == .trash) { return b.action == .trash }
            if a.action == .trash { return a.path > b.path }
            return a.path < b.path
        }
        let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<String>(), ordered: [SyncStep] = []
        func visit(_ step: SyncStep) {
            guard visited.insert(step.id).inserted else { return }
            for dependency in step.dependsOn { if let required = byID[dependency] { visit(required) } }
            ordered.append(step)
        }
        for step in sorted { visit(step) }
        return .init(steps: ordered)
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
        guard row.status != .same, let entry = source == .left ? row.left : row.right else { return nil }
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
