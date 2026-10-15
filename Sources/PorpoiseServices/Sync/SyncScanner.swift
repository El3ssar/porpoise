import Darwin
import Foundation
import PorpoiseCore

public enum SyncEngineError: Error, LocalizedError {
    case unsafePath(String), stale(String), unsupported(String), conflicts, invalidState
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Unsafe sync path: \(path)"
        case .stale(let path): return "Changed since the preview; compare again: \(path)"
        case .unsupported(let text): return text
        case .conflicts: return "Resolve conflicts before syncing."
        case .invalidState: return "This sync state belongs to a different pair or version."
        }
    }
}

public enum SyncScanner {
    /// Independent roots scan concurrently; the returned snapshots are also the baseline inputs for planning.
    public static func compare(
        _ leftRoot: URL, _ rightRoot: URL, options: SyncCompareOptions = .init(),
        cancellation: DiskCancellation = DiskCancellation()
    ) throws
        -> (left: SyncSnapshot, right: SyncSnapshot, comparison: SyncComparison)
    {
        let lock = NSLock()
        var results: [Result<SyncSnapshot, Error>?] = [nil, nil]
        let roots = [leftRoot, rightRoot]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = Result { try scan(roots[index], options: options, cancellation: cancellation) }
            lock.withLock { results[index] = result }
        }
        let left = try results[0]!.get(), right = try results[1]!.get()
        return (left, right, SyncComparator.compare(left, right, options: options))
    }

    /// Throws on unreadable/missing roots or interrupted listings; never publishes a partial scan as complete.
    /// maxDepth = 1 lists immediate children for lazy compare browsing; nil scans the entire tree for planning.
    public static func scan(
        _ root: URL, options: SyncCompareOptions = .init(), maxDepth: Int? = nil,
        caseSensitive: Bool? = nil, cancellation: DiskCancellation = DiskCancellation()
    ) throws -> SyncSnapshot {
        let provider = RemoteFS.provider(for: root)
        var rootIdentity: String?
        if provider == nil {
            let entry = try localEntry(root, path: "root", content: false, cancellation: cancellation)
            rootIdentity = entry.identity
            guard entry.kind == .directory else { throw SyncEngineError.unsupported("Choose a physical folder as the sync root.") }
        }
        let sensitive =
            try caseSensitive
            ?? (provider == nil
                ? (try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true) : true)
        var entries: [SyncEntry] = [], pending: [(URL, String, Int)] = [(root, "", 0)]
        while let (folder, prefix, depth) = pending.popLast() {
            try cancellation.check()
            if let maxDepth, depth >= maxDepth { continue }
            let items: [(URL, String, FileItem?, DiskEntry?)]
            if let provider {
                items = try provider.list(folder).map { (folder.appendingPathComponent($0.name), $0.name, $0, nil) }
            } else {
                items = try PhysicalTreeScanner.children(folder, cancellation: cancellation, strict: true).map {
                    ($0.url, $0.url.lastPathComponent, nil, $0)
                }
            }
            for (url, name, item, disk) in items {
                try cancellation.check()
                guard SyncEntry.isSafePath(name), !name.contains("/") else { throw SyncEngineError.unsafePath(name) }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                // Internal recovery/trash data never enters the user's pair.
                if name == ".porpoise-trash" || name.hasPrefix(".porpoise-sync-") || SyncComparator.excluded(path, patterns: options.exclusions) {
                    continue
                }
                let entry: SyncEntry
                if let item, let provider {
                    let kind: SyncEntryKind = item.isSymlink ? .symlink : (item.isDirectory ? .directory : .file)
                    var hash: String?
                    if options.method == .content && kind == .file {
                        let scratch = try temporaryFolder()
                        defer { try? FileManager.default.removeItem(at: scratch) }
                        let downloaded = try provider.download(url, into: scratch)
                        hash = try FileChecksums.digest(downloaded, cancellation: cancellation)
                    }
                    let modified =
                        options.method == .sizeAndDate && kind == .file
                        ? try (provider as? SyncRemoteMetadata)?.syncModificationDate(url) ?? item.modificationDate : item.modificationDate
                    entry = .init(
                        path: path, kind: kind, size: item.size, modified: modified, hash: hash, linkTarget: item.linkDestination)
                } else if let disk, !disk.symlink {
                    entry = .init(
                        path: path, kind: disk.directory ? .directory : .file, size: disk.size, modified: disk.modified,
                        hash: options.method == .content && !disk.directory
                            ? try FileChecksums.digest(url, expected: disk, cancellation: cancellation) : nil,
                        identity: "\(disk.identity.device):\(disk.identity.inode)")
                } else {
                    entry = try localEntry(url, path: path, content: options.method == .content, cancellation: cancellation)
                }
                entries.append(entry)
                if entry.kind == .directory { pending.append((url, path, depth + 1)) }
            }
        }
        return .init(entries: entries, caseSensitive: sensitive, complete: maxDepth == nil, rootIdentity: rootIdentity)
    }
    static func localEntry(_ url: URL, path: String, content: Bool, cancellation: DiskCancellation = DiskCancellation()) throws -> SyncEntry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG || type == S_IFLNK else {
            throw SyncEngineError.unsupported("Special file cannot be synced: \(path)")
        }
        let kind: SyncEntryKind = type == S_IFDIR ? .directory : (type == S_IFLNK ? .symlink : .file)
        return .init(
            path: path, kind: kind, size: Int64(info.st_size),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            hash: content && kind == .file ? try FileChecksums.digest(url, cancellation: cancellation) : nil,
            identity: "\(info.st_dev):\(info.st_ino)",
            linkTarget: kind == .symlink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
    }
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
