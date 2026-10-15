import Darwin
import Foundation
import PorpoiseCore

/// Physical execution boundary for the jobs engine. Run off the main thread, checkpoint after each successful
/// `execute` call, and rescan/replan after any error. Never advance the two-way baseline on a partial run.
public enum SyncExecutor {
    public static func execute(
        _ plan: SyncPlan, leftRoot: URL, rightRoot: URL,
        cancellation: DiskCancellation = DiskCancellation(),
        completed: (SyncStep) throws -> Void = { _ in }
    ) throws {
        guard plan.conflicts.isEmpty else { throw SyncEngineError.conflicts }
        try validateRoots(leftRoot, rightRoot)
        for step in plan.steps {
            try cancellation.check()
            try execute(step, leftRoot: leftRoot, rightRoot: rightRoot, cancellation: cancellation)
            try completed(step)
        }
    }
    public static func execute(
        _ step: SyncStep, leftRoot: URL, rightRoot: URL,
        cancellation: DiskCancellation = DiskCancellation()
    ) throws {
        try cancellation.check()
        try validateRoots(leftRoot, rightRoot)
        for (root, identity) in [(leftRoot, step.leftRootIdentity), (rightRoot, step.rightRootIdentity)] {
            if let identity, root.isFileURL {
                guard try SyncScanner.localEntry(root, path: "root", content: false).identity == identity else {
                    throw SyncEngineError.stale(root.path)
                }
            }
        }
        guard step.action != .conflict else { throw SyncEngineError.conflicts }
        let root = step.target == .left ? leftRoot : rightRoot
        let target = try resolve(step.path, root: root)
        let targetNow = try entry(
            target, path: step.path, content: step.expectedTarget?.hash != nil || step.expectedSource?.hash != nil,
            preciseDate: step.method == .sizeAndDate)
        if applied(step, target: targetNow) { return }
        try validate(targetNow, expected: step.expectedTarget, path: step.path)
        switch step.action {
        case .conflict: throw SyncEngineError.conflicts
        case .mkdir:
            if let provider = RemoteFS.provider(for: target) {
                try provider.makeFolder(target)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
        case .trash:
            // Descendant steps have already been applied. Refuse to sweep in files created after the preview.
            if targetNow?.kind == .directory {
                let children =
                    try RemoteFS.provider(for: target)?.list(target).map(\.name)
                    ?? FileManager.default.contentsOfDirectory(atPath: target.path)
                guard children.isEmpty else { throw SyncEngineError.stale(step.path) }
            }
            try trash(target, root: root)
        case .copy, .replace:
            guard let side = step.source, let path = step.sourcePath, let expected = step.expectedSource else {
                throw SyncEngineError.unsafePath(step.path)
            }
            let source = try resolve(path, root: side == .left ? leftRoot : rightRoot)
            try validate(
                try entry(source, path: path, content: expected.hash != nil, preciseDate: step.method == .sizeAndDate), expected: expected, path: path
            )
            try copy(
                source, to: target, expected: expected, preserveDate: step.method == .sizeAndDate, timestampTolerance: step.timestampTolerance,
                cancellation: cancellation)
        }
    }
    /// Safe crash-window reconciliation: only a verified postcondition skips a previously running step.
    private static func applied(_ step: SyncStep, target: SyncEntry?) -> Bool {
        switch step.action {
        case .conflict: return false
        case .trash: return target == nil
        case .mkdir: return target?.kind == .directory
        case .copy, .replace:
            guard let expected = step.expectedSource, let target else { return false }
            return SyncComparator.statusOf(expected, target, options: .init(method: step.method, timestampTolerance: step.timestampTolerance))
                == .same
        }
    }
    private static func validateRoots(_ left: URL, _ right: URL) throws {
        func overlaps(_ leftPath: String, _ rightPath: String) -> Bool {
            let l = leftPath.isEmpty ? "/" : leftPath, r = rightPath.isEmpty ? "/" : rightPath
            return l == r || l == "/" || r == "/" || (l + "/").hasPrefix(r + "/") || (r + "/").hasPrefix(l + "/")
        }
        guard left.password == nil, right.password == nil else {
            throw SyncEngineError.unsupported("Store connection passwords in Keychain, not sync URLs.")
        }
        guard left != right else { throw SyncEngineError.unsupported("Choose two different folders.") }
        if left.isFileURL && right.isFileURL {
            let l = left.resolvingSymlinksInPath().standardizedFileURL.path
            let r = right.resolvingSymlinksInPath().standardizedFileURL.path
            guard !overlaps(l, r) else {
                throw SyncEngineError.unsupported("Sync folders cannot contain one another.")
            }
        } else if left.scheme == right.scheme && left.host == right.host && left.user == right.user && left.port == right.port {
            let l = left.standardized.path, r = right.standardized.path
            guard !overlaps(l, r) else {
                throw SyncEngineError.unsupported("Sync folders cannot contain one another.")
            }
        }
    }
    static func resolve(_ path: String, root: URL) throws -> URL {
        guard SyncEntry.isSafePath(path) else { throw SyncEngineError.unsafePath(path) }
        var current = root
        let components = path.split(separator: "/").map(String.init)
        // Even an existing ancestor link inside the root must not redirect an operation outside it.
        if root.isFileURL {
            let rootEntry = try SyncScanner.localEntry(root, path: "root", content: false)
            guard rootEntry.kind == .directory else { throw SyncEngineError.unsafePath(root.path) }
        }
        for (index, name) in components.enumerated() {
            current.appendPathComponent(name)
            if index < components.count - 1 {
                guard try entry(current, path: name, content: false)?.kind == .directory else { throw SyncEngineError.unsafePath(path) }
            }
        }
        return current
    }
    private static func entry(_ url: URL, path: String, content: Bool, preciseDate: Bool = false) throws -> SyncEntry? {
        if let provider = RemoteFS.provider(for: url) {
            guard let item = try provider.list(url.deletingLastPathComponent()).first(where: { $0.name == url.lastPathComponent }) else { return nil }
            let kind: SyncEntryKind = item.isSymlink ? .symlink : (item.isDirectory ? .directory : .file)
            var hash: String?
            if content && kind == .file {
                let scratch = try SyncScanner.temporaryFolder(); defer { try? FileManager.default.removeItem(at: scratch) }
                hash = try FileChecksums.digest(provider.download(url, into: scratch))
            }
            let modified =
                preciseDate && kind == .file
                ? try (provider as? SyncRemoteMetadata)?.syncModificationDate(url) ?? item.modificationDate : item.modificationDate
            return .init(path: path, kind: kind, size: item.size, modified: modified, hash: hash, linkTarget: item.linkDestination)
        }
        do { return try SyncScanner.localEntry(url, path: path, content: content) } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }
    private static func validate(_ current: SyncEntry?, expected: SyncEntry?, path: String) throws {
        guard let expected else {
            guard current == nil else { throw SyncEngineError.stale(path) }; return
        }
        guard let current, current.kind == expected.kind, current.identity == expected.identity else { throw SyncEngineError.stale(path) }
        if current.kind == .directory { return }  // Child operations necessarily alter directory size and timestamps.
        guard current.size == expected.size, current.modified == expected.modified, current.linkTarget == expected.linkTarget,
            expected.hash == nil || current.hash == expected.hash
        else { throw SyncEngineError.stale(path) }
    }
    private static func copy(
        _ source: URL, to target: URL, expected: SyncEntry, preserveDate: Bool, timestampTolerance: TimeInterval, cancellation: DiskCancellation
    )
        throws
    {
        let scratch = try SyncScanner.temporaryFolder(); defer { try? FileManager.default.removeItem(at: scratch) }
        let local: URL
        if let provider = RemoteFS.provider(for: source) {
            guard expected.kind != .symlink else { throw SyncEngineError.unsupported("This remote provider cannot safely transfer symbolic links.") }
            local = try provider.download(source, into: scratch)
            if let modified = expected.modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local.path)
            }
        } else {
            local = source
        }
        try cancellation.check()
        if let provider = RemoteFS.provider(for: target) {
            guard expected.kind != .symlink else { throw SyncEngineError.unsupported("This remote provider cannot safely transfer symbolic links.") }
            // Upload under a unique sibling name; a failed connection leaves the original untouched.
            guard let publisher = provider as? SyncRemotePublishing else {
                throw SyncEngineError.unsupported("This remote provider cannot safely publish staged sync files.")
            }
            if preserveDate, let modified = expected.modified {
                let seconds = modified.timeIntervalSince1970
                guard seconds - floor(seconds) <= timestampTolerance else {
                    throw SyncEngineError.unsupported(
                        "This server preserves whole-second timestamps. Increase date tolerance or choose Content comparison.")
                }
            }
            let stagedName = ".porpoise-sync-\(UUID().uuidString)"
            let stagedLocal = scratch.appendingPathComponent(stagedName)
            try FileManager.default.copyItem(at: local, to: stagedLocal)
            let parent = target.deletingLastPathComponent()
            try provider.upload(stagedLocal, into: parent)
            let stagedRemote = parent.appendingPathComponent(stagedName)
            try publisher.publishSyncFile(stagedRemote, to: target, modified: preserveDate ? expected.modified : nil)
        } else {
            // FileJob copies bytes/links into a private sibling; rename publishes only the complete result.
            // Its basename API needs a staging source when aligned rows have different case spellings.
            let namedFolder = scratch.appendingPathComponent("named")
            try FileManager.default.createDirectory(at: namedFolder, withIntermediateDirectories: false)
            let named = namedFolder.appendingPathComponent(target.lastPathComponent)
            try FileManager.default.copyItem(at: local, to: named)
            let staging = target.deletingLastPathComponent().appendingPathComponent(".porpoise-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            let job = FileJob(kind: .copy, sources: [named], destinationFolder: staging)
            job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
            job.onProgress = { [weak job] _ in
                do { try cancellation.check() } catch { job?.cancel() }
            }
            _ = try job.run()
            try cancellation.check()
            if let error = job.errors.first { throw SyncEngineError.unsupported(error) }
            guard let placed = job.results.first else { throw SyncEngineError.stale(target.path) }
            try cancellation.check()
            guard Darwin.rename(placed.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    private static func trash(_ target: URL, root: URL) throws {
        if let provider = RemoteFS.provider(for: target) {
            let folder = root.appendingPathComponent(".porpoise-trash")
            if try entry(folder, path: ".porpoise-trash", content: false) == nil { try provider.makeFolder(folder) }
            guard try entry(folder, path: ".porpoise-trash", content: false)?.kind == .directory else {
                throw SyncEngineError.unsafePath(folder.path)
            }
            let batch = folder.appendingPathComponent(UUID().uuidString)
            try provider.makeFolder(batch)
            try provider.move([target], into: batch)
        } else {
            // No permanent-delete fallback: unavailable Trash is a surfaced failure.
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        }
    }
}
