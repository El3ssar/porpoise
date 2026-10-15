import Foundation

// MARK: - Types

public enum FileOperationKind: String, Sendable {
    case copy, move, link, trash, delete

    public var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .link: return "Linking"
        case .trash: return "Moving to Trash"
        case .delete: return "Deleting"
        }
    }
}

/// What to do when the destination already exists (KIO's RenameDialog choices).
public enum ConflictResolution: Sendable, Equatable {
    case skip
    case overwrite
    case overwriteIfOlder
    case overwriteIfDifferent
    case overwriteIfLarger
    case keepBoth
    case rename(String)
    case writeInto  // merge folders
    case cancel
}

public struct ConflictInfo: Sendable {
    public let source: FileItem
    public let destination: FileItem
    public let suggestedName: String
    /// Remaining known name clashes, including this one; nil when a remote listing cannot establish it.
    public let remainingConflicts: Int?
    public init(source: FileItem, destination: FileItem, suggestedName: String, remainingConflicts: Int? = nil) {
        self.source = source
        self.destination = destination
        self.suggestedName = suggestedName
        self.remainingConflicts = remainingConflicts
    }
}

public struct ConflictAnswer: Sendable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool
    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

/// A reversible record of what a job did, used for Undo/Redo.
public enum UndoRecord: Sendable {
    case created([URL])  // undo: trash these (copies, links, new folders/files)
    case moved([(from: URL, to: URL)])  // undo: move back
    case trashed([(original: URL, inTrash: URL)])
    case renamed(from: URL, to: URL)
    /// Physical moves in execution order, including temporary staging paths.
    case batchRenamed([RenameMove])

    public var label: String {
        switch self {
        case .created: return "Create"
        case .moved: return "Move"
        case .trashed: return "Move to Trash"
        case .renamed: return "Rename"
        case .batchRenamed: return "Batch Rename"
        }
    }
}

/// Progress snapshot published by a running job.
public struct JobProgress: Sendable {
    public enum Phase: String, Sendable { case preparing, transferring }
    public var phase: Phase = .transferring
    public var totalFiles: Int = 0
    public var totalFolders: Int = 0
    public var doneFiles: Int = 0
    public var replacedItems: Int = 0
    public var skippedIdenticalItems: Int = 0

    public var kind: FileOperationKind
    public var totalBytes: Int64
    public var doneBytes: Int64
    public var totalItems: Int
    public var doneItems: Int
    public var currentName: String
    public var destination: URL?
    public init(kind: FileOperationKind, totalBytes: Int64, doneBytes: Int64, totalItems: Int, doneItems: Int, currentName: String, destination: URL?)
    {
        self.kind = kind; self.totalBytes = totalBytes; self.doneBytes = doneBytes; self.totalItems = totalItems
        self.doneItems = doneItems; self.currentName = currentName; self.destination = destination
    }
    public var fraction: Double {
        if totalBytes > 0 { return Double(doneBytes) / Double(totalBytes) }
        return totalItems > 0 ? Double(doneItems) / Double(totalItems) : 0
    }
}

public enum FileOperationError: Error, LocalizedError {
    case cancelled
    /// Stopped where it was, its partial copy kept for resuming later (the app quitting).
    case interrupted
    case intoItself(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .interrupted: return "The operation was interrupted."
        case .intoItself(let n): return "The folder “\(n)” cannot be copied or moved into itself."
        case .failed(let m): return m
        }
    }
}

/// Where an interrupted copy of one file stopped: its partial copy and how many bytes of it are good.
public struct ResumePoint: Codable, Equatable, Sendable {
    public var staging: URL
    public var offset: Int64
    public init(staging: URL, offset: Int64) {
        self.staging = staging
        self.offset = offset
    }
}

/// What a job reports about each of its top-level items as it goes (for the journal that lets an interrupted job
/// be resumed after a relaunch). Called on the job's thread.
public enum JobEvent: Codable, Sendable, Equatable {
    /// Started; `staging` is the hidden item the copy is written to before it takes its name.
    case started(index: Int, staging: URL?)
    /// A resumable copy (a large file) has this many good bytes in its staging file.
    case copied(index: Int, point: ResumePoint)
    /// The item is complete at `target`; a move still removes its source after this.
    case placed(index: Int, target: URL)
    case finished(index: Int, outcome: ItemOutcome)
}

public enum ItemOutcome: String, Codable, Sendable {
    case done, skipped, failed, cancelled
}

// MARK: - FileJob

/// Runs one file operation (copy/move/link/trash/delete) off the main thread.
///
/// Safety rules: an existing destination is never removed before its replacement is complete
/// (overwrites are staged next to the target and renamed into place), copies never overwrite silently,
/// and a failed copy leaves no partial item behind.
public final class FileJob: @unchecked Sendable {
    public let kind: FileOperationKind
    public let sources: [URL]
    public let destinationFolder: URL?
    /// Called on a background thread; must return the user's answer (UI blocks it with a dialog).
    public var resolveConflict: (ConflictInfo) -> ConflictAnswer = { _ in ConflictAnswer(.skip) }
    public var onProgress: (JobProgress) -> Void = { _ in }
    /// Each top-level item's start, resumable progress, placement and end (see `JobEvent`).
    public var onEvent: (JobEvent) -> Void = { _ in }
    /// Partial copies to continue instead of starting over, by source (from a journal, after a relaunch).
    public var resumePoints: [URL: ResumePoint] = [:]
    /// Clone files where the volume can (APFS). Off in tests that need real byte copies on one volume.
    public var allowsClone = true
    /// Upfront name-clash policy; nil asks through resolveConflict.
    public var conflictRule: TransferConflictRule = .ask
    public var comparisonOptions = SyncCompareOptions()
    /// App moves the displaced complete item to Trash; tests may inject an isolated disposal.
    public var disposeReplacedItem: ((URL) throws -> Void)?
    /// Files at least this large are copied in chunks that can resume where they stopped.
    public var resumableSize: Int64 = 8 << 20
    static let chunkSize = 4 << 20
    /// Tests: a wait after each chunk, so a copy lasts long enough to be paused or interrupted.
    public var chunkDelay: TimeInterval = 0

    public private(set) var errors: [String] = []
    /// Items that failed only for lack of permission (the app may retry them with authorization).
    /// Includes items nested in a folder merge.
    public private(set) var denied: [URL] = []
    /// Where each denied copy/move/link was headed (after conflict resolution, e.g. a renamed target).
    public private(set) var deniedTargets: [URL: URL] = [:]
    /// Top-level results (where each source ended up), used to select pasted items.
    public private(set) var results: [URL] = []
    /// Items that could not go to the Trash because their volume has none (network shares, some
    /// external disks). Finder offers to delete these immediately instead.
    public private(set) var untrashable: [URL] = []
    /// Top-level sources that failed (for Retry).
    public private(set) var failedSources: [URL] = []
    public private(set) var completedSources: Set<URL> = []
    public var remainingSources: [URL] { sources.filter { !completedSources.contains($0) } }
    /// A remote transport uses the same thread-safe controls without running this local FileJob.
    public func finishExternal() { lock.withLock { _ended = true } }
    public func checkCancellation() throws { try checkpoint() }

    /// Minimum interval between progress callbacks (tests set 0 to see every chunk).
    var publishInterval: TimeInterval = 0.05

    private let fm = FileManager.default
    private let lock = NSLock()
    private var _cancelled = false
    private var progress: JobProgress
    /// Tree sizes by item, walked once: the total, a skip, a same-volume move and a copy's end all need them.
    private var sizes: [URL: Int64] = [:]
    private var lastPublish = Date.distantPast
    private var sticky: ConflictResolution?
    private var created: [URL] = []
    /// The top-level item being processed (for events), and how deep in a folder merge the job is.
    private var currentIndex = 0
    private var knownConflicts: Set<URL> = []
    private var directorySources: Set<URL> = []
    private var depth = 0
    private var moved: [(URL, URL)] = []
    private var trashed: [(URL, URL)] = []
    /// Byte counters for the file copyfile() is working on.
    private var currentFileBase: Int64 = 0
    private var currentFileCopied: Int64 = 0
    /// First error copyfile() reported through its callback during a recursive copy.
    fileprivate var copyFailure: (code: Int32, path: String?)?

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled || _interrupted }
    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        pauseCondition.lock(); pauseCondition.broadcast(); pauseCondition.unlock()
    }

    // MARK: Pause and interruption

    private let pauseCondition = NSCondition()
    private var _paused = false
    private var _interrupted = false

    /// Stopped between two chunks (or two items) until `resume()`; nothing is lost or started over.
    public var isPaused: Bool { pauseCondition.lock(); defer { pauseCondition.unlock() }; return _paused }
    public func pause() { pauseCondition.lock(); _paused = true; pauseCondition.unlock() }
    public func resume() { pauseCondition.lock(); _paused = false; pauseCondition.broadcast(); pauseCondition.unlock() }

    /// Stops as soon as it can, keeping partial copies and reporting nothing as done (quitting the app: the journal
    /// resumes the job next time). A paused job stops too.
    public func interrupt() {
        lock.lock(); _interrupted = true; lock.unlock()
        pauseCondition.lock(); pauseCondition.broadcast(); pauseCondition.unlock()
    }

    public var isInterrupted: Bool { lock.lock(); defer { lock.unlock() }; return _interrupted }

    /// Waits while paused (inside copyfile(), between its chunks).
    fileprivate func waitWhilePaused() {
        pauseCondition.lock()
        while _paused && !isCancelled { pauseCondition.wait() }
        pauseCondition.unlock()
    }

    /// Waits while paused; throws once cancelled or interrupted.
    func checkpoint() throws {
        pauseCondition.lock()
        while _paused && !isCancelled { pauseCondition.wait() }
        pauseCondition.unlock()
        if isInterrupted { throw FileOperationError.interrupted }
        if isCancelled { throw FileOperationError.cancelled }
    }

    public init(kind: FileOperationKind, sources: [URL], destinationFolder: URL? = nil) {
        self.kind = kind
        self.sources = sources
        self.destinationFolder = destinationFolder
        progress = JobProgress(
            kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0,
            currentName: sources.first?.lastPathComponent ?? "", destination: destinationFolder)
    }

    /// `run()` has returned.
    public var hasEnded: Bool { lock.lock(); defer { lock.unlock() }; return _ended }
    private var _ended = false

    /// Runs synchronously. Returns the undo record (nil if nothing happened).
    public func run() throws -> UndoRecord? {
        defer { lock.lock(); _ended = true; lock.unlock() }
        progress.phase = .preparing
        publish(force: true)
        if kind == .copy || kind == .move {
            for source in sources {
                do { _ = try inventory(source, target: destinationFolder?.appendingPathComponent(source.lastPathComponent)) } catch FileOperationError
                    .cancelled
                { return nil } catch FileOperationError.interrupted { return nil } catch
                { /* The actual operation reports unreadable/missing sources. */  }
            }
        }
        progress.phase = .transferring
        publish(force: true)
        for (index, src) in sources.enumerated() {
            if (try? checkpoint()) == nil { break }
            progress.currentName = src.lastPathComponent
            currentIndex = index
            let filesBefore = progress.doneFiles
            let errorsBefore = errors.count + denied.count
            let resultsBefore = results.count
            do {
                try process(src)
            } catch FileOperationError.interrupted {
                break
            } catch FileOperationError.cancelled {
                onEvent(.finished(index: index, outcome: .cancelled))
                break
            } catch {
                record(error, for: src, target: nil)
            }
            let failed = errors.count + denied.count > errorsBefore
            if failed { failedSources.append(src) }
            let skipped = !failed && (kind == .copy || kind == .move || kind == .link) && results.count == resultsBefore
            if !failed { completedSources.insert(src) }
            onEvent(.finished(index: index, outcome: failed ? .failed : skipped ? .skipped : .done))
            progress.doneItems += 1
            if !failed { progress.doneFiles = max(progress.doneFiles, filesBefore + (fileCounts[src] ?? 1)) }
            if directorySources.contains(src), !knownConflicts.isEmpty {
                let prefix = src.standardizedFileURL.path + "/"
                knownConflicts = knownConflicts.filter { $0 != src && !$0.standardizedFileURL.path.hasPrefix(prefix) }
            } else {
                knownConflicts.remove(src)
            }
            publish()
        }
        publish(force: true)
        return undoRecord
    }

    private var undoRecord: UndoRecord? {
        switch kind {
        case .copy, .link: return created.isEmpty ? nil : .created(created)
        case .move: return moved.isEmpty ? nil : .moved(moved.map { (from: $0.0, to: $0.1) })
        case .trash: return trashed.isEmpty ? nil : .trashed(trashed.map { (original: $0.0, inTrash: $0.1) })
        case .delete: return nil
        }
    }

    private func process(_ src: URL) throws {
        switch kind {
        case .copy, .move, .link:
            guard let dest = destinationFolder else { return }
            // The destination is where the items go, so it is resolved fully: dropping a folder onto a symlink to
            // itself must count as "into itself" (a copy would otherwise recurse until the disk is full).
            if kind != .link && Self.isSameOrInside(dest.resolvingSymlinksInPath(), src) {
                throw FileOperationError.intoItself(src.lastPathComponent)
            }
            if let r = try transfer(src, into: dest) { results.append(r) }
        case .trash:
            var out: NSURL?
            do {
                try fm.trashItem(at: src, resultingItemURL: &out)
            } catch  where Self.isTrashUnsupportedError(error) {
                untrashable.append(src)
                return
            }
            if let o = out as URL? { trashed.append((src, o)) }
        case .delete:
            try fm.removeItem(at: src)
        }
    }

    /// Files permission problems separately so the app can offer to authenticate.
    private func record(_ error: Error, for src: URL, target: URL?) {
        if Self.isPermissionError(error) {
            denied.append(src)
            if let t = target { deniedTargets[src] = t }
        } else {
            errors.append(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// EACCES/EPERM, however Foundation wraps it.
    public static func isPermissionError(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let n = e {
            if n.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(n.code) { return true }
            if n.domain == NSPOSIXErrorDomain && (n.code == Int(EACCES) || n.code == Int(EPERM)) { return true }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The volume has no Trash (NSFeatureUnsupportedError from `trashItem`).
    public static func isTrashUnsupportedError(_ error: Error) -> Bool {
        let n = error as NSError
        return n.domain == NSCocoaErrorDomain && n.code == NSFeatureUnsupportedError
    }

    private func publish(force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastPublish) > publishInterval {
            lastPublish = now
            onProgress(progress)
        }
    }

    // MARK: Transfer (copy / move / link)

    private enum Placement { case new, replace, merge }

    /// Copies/moves/links one item into `folder`, asking about conflicts. Returns the resulting URL
    /// (nil when skipped or denied).
    private func transfer(_ src: URL, into folder: URL) throws -> URL? {
        try checkpoint()
        // Moving an item to the folder it is already in: nothing to do, but it is still the result.
        if kind == .move && Self.isSame(folder.appendingPathComponent(src.lastPathComponent), src) {
            return src
        }
        guard let (target, placement) = try resolveTarget(for: src, in: folder) else { return nil }
        do {
            if placement == .merge {
                try merge(src, into: target)
                return target
            }
            return try place(src, at: target, replacing: placement == .replace)
        } catch FileOperationError.cancelled {
            throw FileOperationError.cancelled
        } catch FileOperationError.interrupted {
            throw FileOperationError.interrupted
        } catch  where Self.isPermissionError(error) {
            record(error, for: src, target: target)
            return nil
        }
    }

    /// Picks the target URL, asking the user while it exists. nil = skip.
    private func resolveTarget(for src: URL, in folder: URL) throws -> (URL, Placement)? {
        var target = folder.appendingPathComponent(src.lastPathComponent)
        // Copying onto itself (paste in the same folder) → automatic "copy" name, like Dolphin's Duplicate.
        if Self.isSame(target, src) {
            target = folder.appendingPathComponent(FileFormat.duplicateName(for: src.lastPathComponent, existing: names(in: folder)))
        }
        while Self.itemExists(at: target) {
            if isCancelled { throw FileOperationError.cancelled }
            let srcItem = FileItem.load(src)
            let dstItem = FileItem.load(target)
            // A link to a folder is transferred as the link: there is nothing in it to merge.
            let srcIsFolder = (srcItem?.isBrowsableFolder ?? false) && !(srcItem?.isSymlink ?? false)
            let bothDirs = srcIsFolder && (dstItem?.isBrowsableFolder ?? false)
            let physicalFolders =
                srcItem?.isDirectory == true && srcItem?.isSymlink == false
                && dstItem?.isDirectory == true && dstItem?.isSymlink == false
            // Only worked out when needed: listing the folder for every conflict of a big merge is quadratic.
            let suggestion = { FileFormat.suggestedName(for: src.lastPathComponent, existing: self.names(in: folder)) }
            let answer = conflictAnswer(srcItem, dstItem, bothDirs: bothDirs, suggestion: suggestion)
            switch answer {
            case .cancel:
                cancel()
                throw FileOperationError.cancelled
            case .skip:
                return skipped(src)
            case .keepBoth:
                target = folder.appendingPathComponent(suggestion())
            case .rename(let name):
                guard FileActions.isValidName(name) else { throw FileOperationError.failed("“\(name)” is not a valid name.") }
                target = folder.appendingPathComponent(name)  // loop: the new name may exist too
            case .writeInto:
                return bothDirs ? (target, .merge) : skipped(src)
            case .overwriteIfOlder, .overwriteIfDifferent, .overwriteIfLarger:
                guard !physicalFolders else { return (target, .merge) }
                guard let source = srcItem, let destination = dstItem else { return skipped(src) }
                if answer == .overwriteIfDifferent {
                    if try identical(source, destination) { return skipped(src, identical: true) }
                    return try replaceable(target, by: src)
                }
                return answer.shouldReplace(source: source, destination: destination, options: comparisonOptions)
                    ? try replaceable(target, by: src) : skipped(src)
            case .overwrite:
                return bothDirs ? (target, .merge) : try replaceable(target, by: src)
            }
        }
        return (target, .new)
    }

    private func conflictAnswer(_ src: FileItem?, _ dst: FileItem?, bothDirs: Bool, suggestion: () -> String) -> ConflictResolution {
        defer { if let src { knownConflicts.remove(src.url) } }
        // "Apply to All" answers stick, except Write Into, which only means something for two folders.
        if let s = sticky ?? conflictRule.resolution, !(s == .writeInto && !bothDirs) {
            if case .rename = s { return .rename(suggestion()) }
            return s
        }
        guard let s = src, let d = dst else { return .skip }
        let a = resolveConflict(
            ConflictInfo(
                source: s, destination: d, suggestedName: suggestion(), remainingConflicts: max(1, knownConflicts.count)))
        knownConflicts.remove(s.url)
        if a.applyToAll { sticky = a.resolution }
        return a.resolution
    }

    private func skipped(_ src: URL, identical: Bool = false) -> (URL, Placement)? {
        if identical { progress.skippedIdenticalItems += fileCounts[src] ?? 1 }
        progress.doneBytes += size(of: src)
        return nil
    }

    /// Overwriting a folder with something inside it would delete the source too.
    private func replaceable(_ target: URL, by src: URL) throws -> (URL, Placement) {
        if Self.isSameOrInside(src, target) {
            throw FileOperationError.failed("“\(target.lastPathComponent)” cannot be overwritten by an item inside it.")
        }
        return (target, .replace)
    }

    /// Writes `src` to `target`. A copy is written under a hidden name next to the target and takes the target's
    /// name only once complete, so neither a failed nor an interrupted copy ever sits at the target (and a replaced
    /// item is removed only then). Links and moves within a volume are a single step.
    private func place(_ src: URL, at target: URL, replacing: Bool) throws -> URL {
        let sameVolumeMove = kind == .move && Self.sameVolume(src, target.deletingLastPathComponent())
        let copying = kind != .link && !sameVolumeMove
        let top = depth == 0
        // A path too long for a hidden name next to it is written in place, as before.
        var dest = replacing ? Self.stagingURL(for: target) : copying ? Self.copyStagingURL(for: target, of: src) ?? target : target
        var resumeFrom: Int64 = 0
        if copying, top, let point = resumePoints[src], Self.itemExists(at: point.staging) {
            dest = point.staging
            resumeFrom = point.offset
        }
        if top { onEvent(.started(index: currentIndex, staging: copying ? dest : nil)) }
        var renamed = false
        switch kind {
        case .link:
            try fm.createSymbolicLink(at: dest, withDestinationURL: src)
        case .move where sameVolumeMove:
            try fm.moveItem(at: src, to: dest)
            renamed = true
            progress.doneBytes += size(of: src)  // what was there before the rename
        default:
            do {
                try copyItem(src, to: dest, resumeFrom: resumeFrom, report: top)
            } catch FileOperationError.interrupted {
                throw FileOperationError.interrupted  // the partial copy stays, to be resumed
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }
        }
        if replacing {
            // Swap publishes atomically and leaves the displaced item at our staging path. If archiving it
            // fails, swap back before reporting the error: the old target must never disappear on failure.
            var swapped = false
            do {
                guard renamex_np(dest.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                swapped = true
                if let disposeReplacedItem { try disposeReplacedItem(dest) } else { try fm.removeItem(at: dest) }
            } catch {
                if swapped { _ = renamex_np(dest.path, target.path, UInt32(RENAME_SWAP)) }
                if renamed { try? fm.moveItem(at: dest, to: src) } else { try? fm.removeItem(at: dest) }
                throw error
            }
        } else if dest != target {
            // Never over an item that appeared meanwhile (another job pasting the same name): that one stays.
            if renamex_np(dest.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                try? fm.removeItem(at: dest)
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Could not copy “\(src.lastPathComponent)”: \(String(cString: strerror(code)))"])
            }
        }
        if replacing { progress.replacedItems += fileCounts[src] ?? 1 }
        if top { onEvent(.placed(index: currentIndex, target: target)) }
        if kind == .move {
            // Cross-volume: the copy is complete, so the original can go now.
            if !renamed { try fm.removeItem(at: src) }
            moved.append((src, target))
        } else {
            created.append(target)
        }
        return target
    }

    /// Copies one item to `dest`. Large files are cloned where the volume can, else copied in chunks that can
    /// pause and resume (`resumeFrom` bytes already there); everything else goes through copyfile().
    private func copyItem(_ src: URL, to dest: URL, resumeFrom: Int64, report: Bool) throws {
        var st = stat()
        guard lstat(src.path, &st) == 0 else { return try copyRecursively(src, to: dest) }
        let size = Int64(st.st_size)
        guard st.st_mode & S_IFMT == S_IFREG, size >= resumableSize else { return try copyRecursively(src, to: dest) }
        if resumeFrom == 0, allowsClone, clonefile(src.path, dest.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            progress.doneBytes += size
            publish()
            return
        }
        try copyInChunks(src, to: dest, from: resumeFrom, report: report)
    }

    /// A regular file copied a chunk at a time, stopping between chunks while paused. Interrupted, the bytes
    /// written so far stay (flushed, and reported with `.copied`) for a later job to continue from.
    private func copyInChunks(_ src: URL, to dest: URL, from start: Int64, report: Bool) throws {
        func posix(_ what: String) -> NSError {
            let code = errno
            return NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not copy “\(src.lastPathComponent)”: \(String(cString: strerror(code)))"])
        }
        let input = open(src.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw posix("open") }
        defer { close(input) }
        var offset: Int64 = 0
        let output: Int32
        if start > 0 {
            output = open(dest.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw posix("open") }
            var ds = stat()
            fstat(output, &ds)
            // Only what was written before (and flushed) counts.
            offset = min(start, Int64(ds.st_size))
            guard ftruncate(output, off_t(offset)) == 0, lseek(input, off_t(offset), SEEK_SET) == off_t(offset),
                lseek(output, off_t(offset), SEEK_SET) == off_t(offset)
            else {
                close(output)
                throw posix("seek")
            }
        } else {
            output = open(dest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw posix("create") }
        }
        defer { close(output) }
        progress.doneBytes += offset
        publish()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var lastReport = Date()
        func reportPoint() {
            guard report else { return }
            fsync(output)
            onEvent(.copied(index: currentIndex, point: ResumePoint(staging: dest, offset: offset)))
            lastReport = Date()
        }
        while true {
            do {
                try checkpoint()
            } catch FileOperationError.interrupted {
                reportPoint()
                throw FileOperationError.interrupted
            }
            let n = read(input, buffer, Self.chunkSize)
            if n < 0 { throw posix("read") }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = write(output, buffer + written, n - written)
                if w < 0 { throw posix("write") }
                written += w
            }
            offset += Int64(n)
            progress.doneBytes += Int64(n)
            publish()
            if Date().timeIntervalSince(lastReport) > 1 { reportPoint() }
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
        }
        // Permissions, dates, extended attributes and ACLs, as copyfile() would have copied them.
        copyfile(src.path, dest.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_STAT))
    }

    /// "Write Into": transfers the children one by one; a failing child doesn't stop the others.
    private func merge(_ src: URL, into target: URL) throws {
        depth += 1
        defer { depth -= 1 }
        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        for child in children {
            try checkpoint()
            do {
                _ = try transfer(child, into: target)
            } catch FileOperationError.cancelled {
                throw FileOperationError.cancelled
            } catch FileOperationError.interrupted {
                throw FileOperationError.interrupted
            } catch {
                errors.append(Self.describe(error))
            }
        }
        // A merged move leaves the source folder empty; rmdir() refuses if anything is left behind.
        if kind == .move { rmdir(src.path) }
    }

    /// copyfile() with byte progress and cancellation; clones on APFS when possible. Never overwrites
    /// (COPYFILE_EXCL) and removes a partial copy when it fails.
    private func copyRecursively(_ src: URL, to dst: URL) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        let cb: copyfile_callback_t = { what, stage, state, src, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let job = Unmanaged<FileJob>.fromOpaque(ctx).takeUnretainedValue()
            if stage == COPYFILE_PROGRESS { job.waitWhilePaused() }
            if job.isCancelled { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR {
                // In recursive mode errors arrive here. Continuing after a content error would silently
                // skip the item and report an incomplete copy as done (a cross-volume move would then
                // delete the source). Metadata errors (xattrs, folder attributes on FAT/SMB) are tolerated.
                guard
                    what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR || what == COPYFILE_RECURSE_ERROR
                        || what == COPYFILE_COPY_DATA
                else { return COPYFILE_CONTINUE }
                job.copyFailure = (errno, src.map { String(cString: $0) })
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                job.dataProgress(Int64(copied))
            } else if what == COPYFILE_COPY_DATA && stage == COPYFILE_FINISH {
                job.fileFinished()
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START, let s = src {
                job.progress.currentName = (String(cString: s) as NSString).lastPathComponent
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE | COPYFILE_EXCL)
        currentFileBase = progress.doneBytes
        currentFileCopied = 0
        copyFailure = nil
        if copyfile(src.path, dst.path, state, flags) != 0 || copyFailure != nil {
            let code = copyFailure?.code ?? errno
            let failed = copyFailure?.path.map { ($0 as NSString).lastPathComponent } ?? src.lastPathComponent
            // "Already exists" at the top: someone else's item (another job pasting the same name) — never remove it.
            let topExists = code == EEXIST && (copyFailure?.path == nil || copyFailure?.path == src.path)
            if !topExists { try? fm.removeItem(at: dst) }
            if isInterrupted { throw FileOperationError.interrupted }
            if isCancelled { throw FileOperationError.cancelled }
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not copy “\(failed)”: \(String(cString: strerror(code)))"
                ])
        }
        // Clones report no data progress; account for the bytes anyway.
        let expected = size(of: src)
        if progress.doneBytes < currentFileBase + expected { progress.doneBytes = currentFileBase + expected }
        publish()
    }

    fileprivate func dataProgress(_ copied: Int64) {
        progress.doneBytes += max(0, copied - currentFileCopied)
        currentFileCopied = copied
        publish()
    }

    fileprivate func fileFinished() { currentFileCopied = 0; progress.doneFiles += 1 }

    // MARK: Helpers

    private func names(in folder: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Exists, including dangling symlinks (which `fileExists` reports as missing).
    public static func itemExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Hidden sibling a new copy is written to, within the limits on names and paths (nil when the folder's path
    /// leaves no room).
    static func copyStagingURL(for target: URL, of src: URL) -> URL? {
        var name = Substring(target.lastPathComponent)
        while name.utf8.count > 200 { name = name.dropLast() }
        let url = target.deletingLastPathComponent().appendingPathComponent(".\(name).porpoise-\(UUID().uuidString.prefix(8))")
        // A folder's insides get longer paths under the hidden name: its deepest one must still fit.
        var inside = 0
        var st = stat()
        if lstat(src.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
            let e = FileManager.default.enumerator(atPath: src.path)
            while let rel = e?.nextObject() as? String { inside = max(inside, rel.utf8.count + 1) }
        }
        return url.path.utf8.count + inside < Int(PATH_MAX) - 1 ? url : nil
    }

    /// Hidden sibling used while an overwrite is in progress.
    static func stagingURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).porpoise-\(UUID().uuidString.prefix(8))")
    }

    /// Whether `url` is `folder` or inside it, comparing real paths (/tmp vs /private/tmp). The last
    /// component of `url` is kept as is, so a symlink to a folder is not confused with the folder.
    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let f = realPath(folder)
        return (realPath(url) + "/").hasPrefix(f == "/" ? "/" : f + "/")
    }

    /// The same path once the folders leading to it are resolved: the folder an item is in, reached through a link.
    static func isSame(_ a: URL, _ b: URL) -> Bool { realPath(a) == realPath(b) }

    private static func realPath(_ u: URL) -> String {
        let s = u.standardizedFileURL
        return s.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(s.lastPathComponent).path
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let x = ka, let y = kb else { return false }
        return x.isEqual(y)
    }

    private func identical(_ source: FileItem, _ destination: FileItem) throws -> Bool {
        var left = TransferComparison.entry(source), right = TransferComparison.entry(destination)
        if comparisonOptions.method == .content, left.kind == .file, right.kind == .file, left.size == right.size {
            left.hash = try digest(source.url)
            right.hash = try digest(destination.url)
        }
        return SyncComparator.statusOf(left, right, options: comparisonOptions) == .same
    }

    private func digest(_ url: URL) throws -> String {
        try checkpoint()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(file.fileDescriptor, &before) == 0 else { throw FileOperationError.failed("Could not read “\(url.lastPathComponent)”.") }
        var hasher = ChecksumHasher(.sha256)
        while true {
            try checkpoint()
            guard let data = try file.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data)
        }
        guard fstat(file.fileDescriptor, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw FileOperationError.failed("“\(url.lastPathComponent)” changed while comparing; try again.") }
        return hasher.finalize()
    }

    private var fileCounts: [URL: Int] = [:]

    /// Inventory without following directory symlinks. Cancellation/pause remains responsive while counting.
    @discardableResult
    private func inventory(_ url: URL, target: URL?) throws -> Int64 {
        try checkpoint()
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if let target, Self.itemExists(at: target), !Self.isSame(url, target) { knownConflicts.insert(url) }
        let directory = st.st_mode & S_IFMT == S_IFDIR
        var bytes: Int64 = directory || st.st_mode & S_IFMT == S_IFLNK ? 0 : Int64(st.st_size)
        var files = directory ? 0 : 1
        if directory {
            directorySources.insert(url)
            progress.totalFolders += 1
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                bytes += try inventory(child, target: target?.appendingPathComponent(child.lastPathComponent))
                files += fileCounts[child] ?? 0
            }
        } else {
            progress.totalFiles += 1
            progress.totalBytes += bytes
        }
        progress.currentName = url.lastPathComponent
        sizes[url] = bytes
        fileCounts[url] = files
        publish()
        return bytes
    }

    private func size(of url: URL) -> Int64 {
        if let s = sizes[url] { return s }
        let s = Self.diskSize(url)
        sizes[url] = s
        return s
    }

    /// Total size of a file or folder tree (logical sizes). Symlinks count as themselves, not their
    /// target, matching how they are copied.
    public static func diskSize(_ url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return (st.st_mode & S_IFMT) == S_IFREG ? Int64(st.st_size) : 0 }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - FileActions

/// Small synchronous helpers for single-step operations.
public enum FileActions {
    /// Creates a folder; "a/b" creates nested folders (Dolphin allows slashes).
    public static func makeFolder(named name: String, in folder: URL) throws -> URL {
        guard !name.scalarComponents(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileOperationError.failed("“\(name)” is not a valid name.")
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a file, failing (atomically, no race) if one with that name exists.
    public static func makeFile(named name: String, in folder: URL, contents: Data = Data()) throws -> URL {
        let url = folder.appendingPathComponent(name)
        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
            throw FileOperationError.failed("A file named “\(name)” already exists.")
        }
        return url
    }

    public static func rename(_ url: URL, to newName: String) throws -> URL {
        guard isValidName(newName) else { throw FileOperationError.failed("“\(newName)” is not a valid name.") }
        let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
        if dst.path == url.path { return url }
        // A case-only change ("a" → "A") is the same file on a case-insensitive volume.
        if FileJob.itemExists(at: dst) && dst.path.lowercased() != url.path.lowercased() {
            throw FileOperationError.failed("A file named “\(newName)” already exists.")
        }
        try FileManager.default.moveItem(at: url, to: dst)
        return dst
    }

    /// A single path component: not empty, no "/", not "." or "..".
    public static func isValidName(_ name: String) -> Bool { RemoteParsing.isSafeName(name) }

    /// Validation message for a new name (KIO's folder dialog), nil when fine.
    public static func validateName(_ name: String, in folder: URL, allowSlash: Bool) -> (message: String, isError: Bool)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ("", true) }
        if name == "." || name == ".." { return ("“\(name)” is not a valid name.", true) }
        if !allowSlash && name.containsScalar("/") { return ("A name cannot contain “/”.", true) }
        if name.scalarComponents(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }) {
            return ("“\(name)” is not a valid name.", true)
        }
        // itemExists: a dangling symlink also takes the name.
        if FileJob.itemExists(at: folder.appendingPathComponent(name)) {
            return ("A file or folder with this name already exists.", true)
        }
        if name.hasPrefix(".") { return ("The name starts with a dot, so it will be hidden by default.", false) }
        if allowSlash && name.containsScalar("/") { return ("Using slashes in the name will create subfolders.", false) }
        if name != trimmed { return ("The name has leading or trailing spaces.", false) }
        return nil
    }

    /// Reverts an undo record and returns the redo record. All or nothing: if a step fails, the steps
    /// already done are rolled back and the error is thrown, so the record stays valid for another try.
    public static func undo(_ record: UndoRecord) throws -> UndoRecord? {
        switch record {
        case .created(let urls):
            // Items deleted since then have nothing left to undo.
            let trashed = try trashAll(urls.filter { FileJob.itemExists(at: $0) })
            return trashed.isEmpty ? nil : .trashed(trashed.map { (original: $0.0, inTrash: $0.1) })
        case .moved(let pairs):
            try moveAll(pairs.reversed().map { ($0.to, $0.from) })
            return .moved(pairs.map { (from: $0.to, to: $0.from) })
        case .trashed(let pairs):
            try moveAll(pairs.reversed().map { ($0.inTrash, $0.original) })
            return .moved(pairs.map { (from: $0.inTrash, to: $0.original) })
        case .renamed(let from, let to):
            try FileManager.default.moveItem(at: to, to: from)
            return .renamed(from: to, to: from)
        case .batchRenamed(let steps):
            let inverse = steps.reversed().map { RenameMove(from: $0.to, to: $0.from) }
            try moveAll(inverse.map { ($0.from, $0.to) })
            return .batchRenamed(inverse)
        }
    }

    /// Moves each pair (recreating missing parent folders, e.g. a source folder emptied by a merge);
    /// on failure moves the finished ones back.
    private static func moveAll(_ moves: [(URL, URL)]) throws {
        let fm = FileManager.default
        var done: [(URL, URL)] = []
        do {
            for (from, to) in moves {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            for (from, to) in done.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
    }

    private static func trashAll(_ urls: [URL]) throws -> [(URL, URL)] {
        let fm = FileManager.default
        var trashed: [(URL, URL)] = []
        do {
            for u in urls {
                var out: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &out)
                if let o = out as URL? { trashed.append((u, o)) }
            }
        } catch {
            for (original, inTrash) in trashed.reversed() { try? fm.moveItem(at: inTrash, to: original) }
            throw error
        }
        return trashed
    }
}
