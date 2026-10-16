import Foundation
import PorpoiseCore
import UniformTypeIdentifiers

/// A disk-free projection of scanner entries into Porpoise's ordinary Details row model.
public struct CompareDetailsPresentation {
    public var rows: [Row] = []
    public var slots: [Int] = []
    public var hasNestedRows = false
    public var pathAliases: [String: String] = [:]
    public var folderCounts: [URL: Int] = [:]
    public var counts: (folders: Int, files: Int, bytes: Int64) = (0, 0, 0)
    public init(_ differences: [SyncDifference], root: URL, side: SyncSide, expanded: Set<String>, folderCounts: [String: Int] = [:]) {
        rows.reserveCapacity(differences.count); slots.reserveCapacity(differences.count)
        var types: [String: String] = [:]
        for (slot, difference) in differences.enumerated() {
            guard let entry = side == .left ? difference.left : difference.right else { continue }
            let url = root.appendingPathComponent(entry.path)
            let name = url.lastPathComponent, ext = url.pathExtension.lowercased()
            let directory = entry.kind == .directory
            let package = directory && ["app", "bundle", "framework"].contains(ext)
            if !directory, types[ext] == nil { types[ext] = UTType(filenameExtension: ext)?.identifier ?? "public.data" }
            let item = FileItem(
                url: url, name: name, isDirectory: directory, isSymlink: entry.kind == .symlink,
                isHidden: name.hasPrefix("."), isPackage: package, isApplication: directory && ext == "app",
                size: entry.size, modificationDate: entry.modified,
                contentType: directory ? "public.folder" : types[ext], linkDestination: entry.linkTarget)
            let depth = entry.path.split(separator: "/").count - 1
            hasNestedRows = hasNestedRows || depth > 0
            rows.append(Row(item: item, depth: depth, isExpanded: expanded.contains(difference.path)))
            slots.append(slot)
            if let count = folderCounts[difference.path], directory { self.folderCounts[url] = count }
            if entry.path != difference.path { pathAliases[entry.path] = difference.path }
            if depth == 0 {
                if item.isBrowsableFolder { counts.folders += 1 } else { counts.files += 1; counts.bytes += item.size }
            }
        }
    }
}
