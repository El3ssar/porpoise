import CoreGraphics
import Foundation

public final class DiskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let owningCancelled: () -> Bool
    private let checkpoint: (() throws -> Void)?
    /// Optional owning-job pause/cancel gate, called outside the cancellation lock at safe IO boundaries.
    public init(checkpoint: (() throws -> Void)? = nil, isCancelled: @escaping () -> Bool = { false }) {
        self.checkpoint = checkpoint; self.owningCancelled = isCancelled
    }
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } || owningCancelled() }
    public func check() throws {
        if isCancelled { throw CancellationError() }
        try checkpoint?()
    }
}
public struct DiskIdentity: Hashable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public init(device: Int32, inode: UInt64) { self.device = device; self.inode = inode }
}
public struct DiskEntry: Sendable, Equatable {
    public var url: URL
    public var identity: DiskIdentity
    public var directory: Bool
    public var symlink: Bool
    public var size: Int64
    public var allocated: Int64
    public var modified: Date
    public init(url: URL, identity: DiskIdentity, directory: Bool, symlink: Bool = false, size: Int64, allocated: Int64, modified: Date) {
        self.url = url; self.identity = identity; self.directory = directory; self.symlink = symlink; self.size = size; self.allocated = allocated;
        self.modified = modified
    }
}
public struct DiskScan: Sendable {
    public var entries: [DiskEntry] = []
    public var errors: [String] = []
    public var cancelled = false
    public init() {}
}
public struct UsageNode: Sendable {
    public var url: URL?
    public var parent: Int?
    public var children: [Int] = []
    public var logical: Int64 = 0
    public var allocated: Int64 = 0
    public var files = 0
    public var directory: Bool
    public var name: String { url?.lastPathComponent ?? "Selection" }
}
public struct UsageTree: Sendable {
    public var nodes: [UsageNode]
    public let hardLinkAliases: Int
    public init(_ scan: DiskScan) {
        var nodes = [UsageNode(url: nil, parent: nil, directory: true)]
        var paths: [String: Int] = [:], seen: Set<DiskIdentity> = [], aliases = 0
        // Depth first in the logical tree; stable path ordering assigns hard-link bytes deterministically.
        for entry in scan.entries.sorted(by: { $0.url.path < $1.url.path }) {
            let id = nodes.count, parent = paths[entry.url.deletingLastPathComponent().path] ?? 0
            var node = UsageNode(url: entry.url, parent: parent, directory: entry.directory)
            if !entry.directory && !entry.symlink {
                if seen.insert(entry.identity).inserted {
                    node.logical = entry.size; node.allocated = entry.allocated; node.files = 1
                } else {
                    aliases += 1
                }
            }
            nodes.append(node); nodes[parent].children.append(id); paths[entry.url.path] = id
        }
        for id in nodes.indices.reversed() where id != 0 {
            let parent = nodes[id].parent!
            nodes[parent].logical += nodes[id].logical; nodes[parent].allocated += nodes[id].allocated; nodes[parent].files += nodes[id].files
        }
        self.nodes = nodes; hardLinkAliases = aliases
    }
}

public struct DuplicateFile: Sendable, Equatable {
    public var entry: DiskEntry
    public var cloneID: UInt64?
    public init(entry: DiskEntry, cloneID: UInt64? = nil) { self.entry = entry; self.cloneID = cloneID }
}
public struct DuplicateGroup: Sendable {
    public var digest: String
    public var files: [DuplicateFile]
    public init(digest: String, files: [DuplicateFile]) { self.digest = digest; self.files = files }
    public var logicalSavings: Int64 { Int64(max(0, files.count - 1)) * (files.first?.entry.size ?? 0) }
    public func isClone(_ file: DuplicateFile) -> Bool {
        guard let clone = file.cloneID, clone != 0 else { return false }
        return files.contains {
            $0.entry.identity != file.entry.identity && $0.entry.identity.device == file.entry.identity.device && $0.cloneID == clone
        }
    }

    /// `isClone` for every file at once (one pass, for showing thousands of copies).
    public var clones: [Bool] {
        var families: [String: Set<UInt64>] = [:]  // "device:clone" → inodes
        for f in files {
            guard let c = f.cloneID, c != 0 else { continue }
            families["\(f.entry.identity.device):\(c)", default: []].insert(f.entry.identity.inode)
        }
        return files.map { f in
            guard let c = f.cloneID, c != 0 else { return false }
            return (families["\(f.entry.identity.device):\(c)"]?.count ?? 0) > 1
        }
    }
}
public enum DuplicateKeepRule: String, CaseIterable, Sendable {
    case newest, oldest, shortestPath, inFolder
    public var title: String {
        switch self {
        case .newest: return "Newest";
        case .oldest: return "Oldest";
        case .shortestPath: return "Shortest path";
        case .inFolder: return "In chosen folder"
        }
    }
    /// The copy to keep; for "in chosen folder", nil when no copy is there (the group is left alone).
    public func keeper(in group: DuplicateGroup, preferredFolder: URL? = nil) -> URL? {
        if self == .inFolder, let folder = preferredFolder,
            !group.files.contains(where: { NameIndex.contains(path: $0.entry.url.path, in: folder.path) })
        {
            return nil
        }
        return group.files.min { a, b in
            let x = a.entry, y = b.entry
            switch self {
            case .newest: if x.modified != y.modified { return x.modified > y.modified }
            case .oldest: if x.modified != y.modified { return x.modified < y.modified }
            case .shortestPath: if x.url.path.utf8.count != y.url.path.utf8.count { return x.url.path.utf8.count < y.url.path.utf8.count }
            case .inFolder:
                if let folder = preferredFolder {
                    let left = NameIndex.contains(path: x.url.path, in: folder.path), right = NameIndex.contains(path: y.url.path, in: folder.path)
                    if left != right { return left }
                }
            }
            return x.url.path < y.url.path
        }?.entry.url
    }

    /// Every copy but each group's keeper (one keeper per group, however many copies it has).
    public func marked(in groups: [DuplicateGroup], preferredFolder: URL? = nil) -> Set<URL> {
        var out = Set<URL>()
        for g in groups {
            guard let keep = keeper(in: g, preferredFolder: preferredFolder) else { continue }
            for f in g.files where f.entry.url != keep { out.insert(f.entry.url) }
        }
        return out
    }
}

/// Slice-and-dice layout with area proportional to byte size; callers draw only one level at a time.
public enum UsageTreemap {
    public struct Tile { public var id: Int; public var rect: CGRect }
    public static func layout(_ weights: [(Int, Int64)], in bounds: CGRect) -> [Tile] {
        let weights = weights.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let sum = weights.reduce(0.0) { $0 + Double($1.1) }
        guard sum > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        func split(_ items: ArraySlice<(Int, Int64)>, _ rect: CGRect) -> [Tile] {
            guard !items.isEmpty else { return [] }
            if items.count == 1 { return [Tile(id: items.first!.0, rect: rect)] }
            let total = items.reduce(0.0) { $0 + Double($1.1) }
            var partial = 0.0, middle = items.startIndex
            while middle < items.endIndex - 1 {
                partial += Double(items[middle].1); middle += 1
                if partial >= total / 2 { break }
            }
            let ratio = partial / total
            var first = rect, second = rect
            if rect.width >= rect.height {
                first.size.width *= ratio; second.origin.x += first.width; second.size.width -= first.width
            } else {
                first.size.height *= ratio; second.origin.y += first.height; second.size.height -= first.height
            }
            return split(items[..<middle], first) + split(items[middle...], second)
        }
        return split(weights[...], bounds)
    }
}
