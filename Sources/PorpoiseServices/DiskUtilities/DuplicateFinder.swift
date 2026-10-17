import Foundation
import PorpoiseCore

public enum DuplicateFinder {
    public struct Result: Sendable {
        public var groups: [DuplicateGroup] = []
        public var errors: [String] = []
        public var hardLinksIgnored = 0
        public var partialHashes = 0
        public var fullHashes = 0
        public init() {}
    }
    public static func find(
        in scan: DiskScan, cancellation: DiskCancellation = DiskCancellation(),
        progress: (DiskProgress) -> Void = { _ in }
    ) throws -> Result {
        var result = Result(), seen: Set<DiskIdentity> = [], sizes: [Int64: [DiskEntry]] = [:], done = 0
        result.errors = scan.errors
        for file in scan.entries.sorted(by: { $0.url.path < $1.url.path }) where !file.directory && !file.symlink && file.size > 0 {
            if seen.insert(file.identity).inserted { sizes[file.size, default: []].append(file) } else { result.hardLinksIgnored += 1 }
        }
        for files in sizes.values where files.count > 1 {
            var partials: [String: [DiskEntry]] = [:]
            for file in files {
                try cancellation.check()
                do {
                    let hash = try FileChecksums.digest(file.url, partial: true, expected: file, cancellation: cancellation)
                    partials[hash, default: []].append(file); result.partialHashes += 1
                } catch is CancellationError { throw CancellationError() } catch {
                    result.errors.append("\(file.url.path): \(error.localizedDescription)")
                }
                done += 1; progress(DiskProgress(files: done, path: file.url.path))
            }
            for candidates in partials.values where candidates.count > 1 {
                var full: [String: [DuplicateFile]] = [:]
                for file in candidates {
                    try cancellation.check()
                    do {
                        let hash = try FileChecksums.digest(file.url, expected: file, cancellation: cancellation)
                        full[hash, default: []].append(DuplicateFile(entry: file, cloneID: CloneIdentity.read(file.url))); result.fullHashes += 1
                    } catch is CancellationError { throw CancellationError() } catch {
                        result.errors.append("\(file.url.path): \(error.localizedDescription)")
                    }
                }
                result.groups.append(
                    contentsOf: full.filter { $0.value.count > 1 }.map {
                        DuplicateGroup(digest: $0.key, files: $0.value.sorted { $0.entry.url.path < $1.entry.url.path })
                    })
            }
        }
        result.groups.sort { $0.logicalSavings == $1.logicalSavings ? $0.digest < $1.digest : $0.logicalSavings > $1.logicalSavings }
        return result
    }
    /// Revalidate both marked copies and keepers before offering the existing undoable Trash operation.
    public static func validate(_ groups: [DuplicateGroup], marked: Set<URL>, cancellation: DiskCancellation = DiskCancellation()) throws -> [URL] {
        let marked = Set(marked.map { URL(fileURLWithPath: FilePath.entry($0.path)) })
        var valid: [URL] = []
        let known = Set(groups.flatMap { $0.files.map(\.entry.url) })
        guard marked.isSubset(of: known) else { throw FileChecksumError.unsafeReview }
        for group in groups {
            let chosen = group.files.filter { marked.contains($0.entry.url) }
            if chosen.isEmpty { continue }
            guard chosen.count < group.files.count else { throw FileChecksumError.noKeeper }
            for file in group.files {
                do {
                    let hash = try FileChecksums.digest(file.entry.url, expected: file.entry, cancellation: cancellation)
                    guard hash == group.digest else { throw FileChecksumError.unsafeReview }
                } catch is CancellationError { throw CancellationError() } catch { throw FileChecksumError.unsafeReview }
            }
            valid.append(contentsOf: chosen.map(\.entry.url))
        }
        return valid.sorted { $0.path < $1.path }
    }
}

/// Shared, bounded short-lived cache for Details content-size requests and utility windows.
public final class FolderUsageCache: @unchecked Sendable {
    public static let shared = FolderUsageCache()
    private struct Cached { var date: Date; var modified: Date?; var size: Int64 }
    private let lock = NSLock()
    private var values: [String: Cached] = [:]
    public init() {}
    public func invalidate(below url: URL) {
        // Keys are real paths (see `size`): so is the folder compared with them.
        let base = FilePath.canonical(url.path)
        lock.withLock { values = values.filter { !FilePath.contains(path: $0.key.components(separatedBy: "\0")[0], in: base) } }
    }
    public func size(_ given: URL, depth: Int, cancellation: DiskCancellation = DiskCancellation()) -> Int64 {
        // A symlink to a folder (shown as a folder) is measured as that folder, not as a link of 0 bytes.
        let url = URL(fileURLWithPath: FilePath.canonical(given.path))
        let key = url.path + "\0" + String(depth)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let hit = lock.withLock({ values[key] }), hit.modified == modified && Date().timeIntervalSince(hit.date) < 3 { return hit.size }
        let measurement = TreeMeasure.measure([url], maxDepth: depth, cancellation: cancellation)
        let size = measurement?.bytes ?? 0
        if let measurement, measurement.errors.isEmpty {
            lock.withLock {
                if values.count >= 512 { values = [:] }
                values[key] = Cached(date: Date(), modified: modified, size: size)
            }
        }
        return size
    }
}
