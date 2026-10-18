import Foundation
import PorpoiseCore

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
    /// Logical destination metadata, loaded on the worker, never a hidden staging path.
    public var onIncoming: ((FileItem?, Int64) -> Void)?
    /// Called off main after a full-disk failure cleans its partial file. True retries this item.
    public var onNoSpace: ((Int64) -> Bool)?
    /// Published leaves in merged folders, retained by an in-session Stop → Resume.
    public var completedTransfers: [URL: URL] = [:]
    /// Each top-level item's start, resumable progress, placement and end (see `JobEvent`).
    public var onEvent: (JobEvent) -> Void = { _ in }
    /// Partial copies to continue instead of starting over, by source (from a journal, after a relaunch).
    public var resumePoints: [URL: ResumePoint] = [:]
    /// Clone files where the volume can (APFS). Off in tests that need real byte copies on one volume.
    public var allowsClone = true
    /// Upfront name-clash policy; nil asks through resolveConflict.
    public var conflictRule: TransferConflictRule = .ask
    public var comparisonOptions = TransferCompareOptions()
    /// App moves the displaced complete item to Trash; tests may inject an isolated disposal.
    public var trashItem: (URL) throws -> URL? = FileActions.trashItem
    public var disposeReplacedItem: ((URL, URL) throws -> Void)?
    /// Files at least this large are copied in chunks that can resume where they stopped.
    public var resumableSize: Int64 = 8 << 20
    static let chunkSize = 4 << 20
    /// Tests: a wait after each chunk, so a copy lasts long enough to be paused or interrupted.
    public var chunkDelay: TimeInterval = 0
    /// Test instrumentation for an observable preparation phase; production leaves this at zero.
    public var inventoryDelay: TimeInterval = 0

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
    public let control: JobControl

    /// Minimum interval between progress callbacks (tests set 0 to see every chunk).
    var publishInterval: TimeInterval = 0.25

    private let fm = FileManager.default
    private var progress: JobProgress
    /// Tree sizes by item, walked once: the total, a skip, a same-volume move and a copy's end all need them.
    private var sizes: [URL: Int64] = [:]
    private var lastPublish = Date.distantPast
    private var sticky: ConflictResolution?
    private var created: [URL] = []
    /// The top-level item being processed (for events), and how deep in a folder merge the job is.
    private var currentIndex = 0
    private var pendingIncoming: (source: URL, target: URL, began: Date, base: Int64, emitted: Bool)?
    private var knownConflicts: Set<URL> = []
    private var inventoryMethod: TransferCompareMethod = .sizeAndDate
    private var childCounts: [URL: Int] = [:]
    private var differentItems = 0
    private var identicalItems = 0
    private var directorySources: Set<URL> = []
    private var depth = 0
    private var moved: [(URL, URL)] = []
    private var trashed: [(URL, URL)] = []
    /// Byte counters for the file copyfile() is working on.
    private var currentFileBase: Int64 = 0
    private var currentFileCopied: Int64 = 0
    /// First error copyfile() reported through its callback during a recursive copy.
    fileprivate var copyFailure: (code: Int32, path: String?)?

    public var isCancelled: Bool { control.isCancelled }
    public var isPaused: Bool { control.isPaused }
    public var isInterrupted: Bool { control.isInterrupted }
    public var hasEnded: Bool { control.hasEnded }
    public func cancel() { control.cancel() }
    public func pause() { control.pause() }
    public func resume() { control.resume() }
    public func interrupt() { control.interrupt() }
    private func checkpoint() throws { try control.checkpoint() }

    public init(kind: FileOperationKind, sources: [URL], destinationFolder: URL? = nil, control: JobControl = JobControl()) {
        self.control = control
        self.kind = kind
        self.sources = sources
        self.destinationFolder = destinationFolder
        progress = JobProgress(
            kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0,
            currentName: sources.first?.lastPathComponent ?? "", destination: destinationFolder)
    }

    /// Runs synchronously. Returns the undo record (nil if nothing happened).
    public func run() throws -> UndoRecord? {
        defer { control.finish() }
        progress.phase = .preparing
        inventoryMethod = comparisonOptions.method
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
            if kind != .link && FilePath(entry: src).contains(FilePath(canonical: dest)) {
                throw FileOperationError.intoItself(src.lastPathComponent)
            }
            if let r = try transfer(src, into: dest) { results.append(r) }
        case .trash:
            do {
                if let out = try trashItem(src) { trashed.append((src, out)) }
            } catch  where Self.isTrashUnsupportedError(error) {
                untrashable.append(src)
            }
        case .delete:
            try fm.removeItem(at: src)
        }
    }

    /// Files permission problems separately so the app can offer to authenticate.
    private func record(_ error: Error, for src: URL, target: URL?) {
        if FileErrorKind.classify(error) == .permission {
            denied.append(src)
            if let t = target { deniedTargets[src] = t }
        } else {
            errors.append(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            // Fast files should neither load display metadata nor enqueue a flash of a placeholder each.
            if let incoming = pendingIncoming, !incoming.emitted, now.timeIntervalSince(incoming.began) >= 0.1,
                let onIncoming, let item = FileItem.load(incoming.source)
            {
                pendingIncoming?.emitted = true
                onIncoming(
                    FileItem(
                        url: incoming.target, name: incoming.target.lastPathComponent, isDirectory: item.isDirectory,
                        isSymlink: item.isSymlink, isHidden: incoming.target.lastPathComponent.hasPrefix("."),
                        isPackage: item.isPackage, isApplication: item.isApplication, size: size(of: incoming.source),
                        modificationDate: item.modificationDate, contentType: item.contentType), incoming.base)
            }
            onProgress(progress)
        }
    }

    // MARK: Transfer (copy / move / link)

    private enum Placement { case new, replace, merge }

    /// Copies/moves/links one item into `folder`, asking about conflicts. Returns the resulting URL
    /// (nil when skipped or denied).
    private func transfer(_ src: URL, into folder: URL) throws -> URL? {
        try checkpoint()
        if let target = completedTransfers[src], Self.itemExists(at: target) {
            progress.doneBytes += size(of: src)
            progress.doneFiles += fileCounts[src] ?? 1
            knownConflicts.remove(src)
            return target
        }
        // Moving an item to the folder it is already in: nothing to do, but it is still the result.
        if kind == .move && FilePath.sameItem(folder.appendingPathComponent(src.lastPathComponent), src) {
            return src
        }
        guard let (target, placement) = try resolveTarget(for: src, in: folder) else { return nil }
        let tracksIncoming = depth == 0 && onIncoming != nil && (kind == .copy || kind == .move)
        if tracksIncoming { pendingIncoming = (src, target, Date(), progress.doneBytes, false) }
        defer {
            if tracksIncoming {
                let incoming = pendingIncoming
                pendingIncoming = nil
                if incoming?.emitted == true { onIncoming?(nil, incoming?.base ?? 0) }
            }
        }
        do {
            if placement == .merge {
                try merge(src, into: target)
                return target
            }
            let result = try place(src, at: target, replacing: placement == .replace)
            completedTransfers[src] = result
            return result
        } catch FileOperationError.cancelled {
            throw FileOperationError.cancelled
        } catch FileOperationError.interrupted {
            throw FileOperationError.interrupted
        } catch  where FileErrorKind.classify(error) == .permission {
            record(error, for: src, target: target)
            return nil
        }
    }

    /// Picks the target URL, asking the user while it exists. nil = skip.
    private func resolveTarget(for src: URL, in folder: URL) throws -> (URL, Placement)? {
        var target = folder.appendingPathComponent(src.lastPathComponent)
        // Copying onto itself (paste in the same folder) → automatic "copy" name, like Dolphin's Duplicate.
        if FilePath.sameItem(target, src) {
            target = folder.appendingPathComponent(FileFormat.duplicateName(for: src.lastPathComponent, existing: names(in: folder)))
        }
        while Self.itemExists(at: target) {
            if isCancelled { throw FileOperationError.cancelled }
            let srcItem = FileItem.load(src)
            let dstItem = FileItem.load(target)
            guard let source = srcItem, let destination = dstItem else { return skipped(src) }
            let policy = ConflictPolicy(source: source, destination: destination, mergePackages: false)
            // Only worked out when needed: listing the folder for every conflict of a big merge is quadratic.
            let suggestion = { FileFormat.suggestedName(for: src.lastPathComponent, existing: self.names(in: folder)) }
            let answer = conflictAnswer(source, destination, policy: policy, suggestion: suggestion)
            var decision = policy.decision(for: answer, suggestedName: suggestion, options: comparisonOptions)
            if decision == .compareContents {
                decision = try identical(source, destination) ? .skip(identical: true) : .replace
            }
            switch decision {
            case .cancel:
                cancel()
                throw FileOperationError.cancelled
            case .skip(let identical): return skipped(src, identical: identical)
            case .rename(let name):
                guard FileActions.isValidName(name) else { throw FileOperationError.failed("“\(name)” is not a valid name.") }
                target = folder.appendingPathComponent(name)  // loop: the new name may exist too
            case .merge: return (target, .merge)
            case .replace: return try replaceable(target, by: src)
            case .compareContents: preconditionFailure("Content comparison must be resolved before placement")
            }
        }
        return (target, .new)
    }

    private func conflictAnswer(_ s: FileItem, _ d: FileItem, policy: ConflictPolicy, suggestion: () -> String) -> ConflictResolution {
        defer { knownConflicts.remove(s.url) }
        if let choice = policy.automaticResolution(sticky: sticky, rule: conflictRule) { return choice }
        let a = resolveConflict(
            ConflictInfo(
                source: s, destination: d, suggestedName: suggestion(), remainingConflicts: max(1, knownConflicts.count),
                comparisonOptions: comparisonOptions,
                replacedItems: progress.replacedItems, skippedIdenticalItems: progress.skippedIdenticalItems,
                differentItems: inventoryMethod == comparisonOptions.method && inventoryMethod != .content ? differentItems : nil,
                identicalItems: inventoryMethod == comparisonOptions.method && inventoryMethod != .content ? identicalItems : nil,
                sourceFolder: policy.isFolderPair ? childCounts[s.url].map { TransferFolderSummary(itemCount: $0, bytes: sizes[s.url]) } : nil,
                destinationFolder: policy.isFolderPair
                    ? (try? fm.contentsOfDirectory(atPath: d.url.path)).map { TransferFolderSummary(itemCount: $0.count) } : nil))
        if let method = a.comparisonMethod { comparisonOptions.method = method }
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
        if FilePath(entry: target).contains(FilePath(entry: src)) {
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
            let bytesBefore = progress.doneBytes
            while true {
                do {
                    try copyItem(src, to: dest, resumeFrom: resumeFrom, report: top)
                    break
                } catch FileOperationError.interrupted {
                    throw FileOperationError.interrupted
                } catch {
                    try? fm.removeItem(at: dest)
                    guard FileErrorKind.classify(error) == .noSpace, let onNoSpace else { throw error }
                    progress.doneBytes = bytesBefore
                    publish(force: true)
                    guard onNoSpace(size(of: src)) else { cancel(); throw FileOperationError.cancelled }
                    resumeFrom = 0
                    try checkpoint()
                }
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
                if let disposeReplacedItem { try disposeReplacedItem(dest, target) } else { try fm.removeItem(at: dest) }
            } catch {
                if swapped, renamex_np(dest.path, target.path, UInt32(RENAME_SWAP)) != 0 {
                    // Another process may have moved the published target. Never clean up the complete old
                    // item when rollback failed: both generations must remain recoverable.
                    throw FileOperationError.failed(
                        "Could not restore the previous item from “\(dest.path)”. The completed replacement may have moved. \(error.localizedDescription)"
                    )
                }
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
        progress.copiedItems += max(1, fileCounts[src] ?? 1)
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
        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
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
            if stage == COPYFILE_PROGRESS { job.control.waitWhilePaused() }
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
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL | (allowsClone ? COPYFILE_CLONE : 0))
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
        return TransferComparator.statusOf(left, right, options: comparisonOptions) == .same
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
        if inventoryDelay > 0 { Thread.sleep(forTimeInterval: inventoryDelay) }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if let target, Self.itemExists(at: target), !FilePath.sameItem(url, target) {
            knownConflicts.insert(url)
            if st.st_mode & S_IFMT != S_IFDIR, inventoryMethod != .content, let source = FileItem.load(url), let destination = FileItem.load(target) {
                let status = TransferComparator.statusOf(
                    TransferComparison.entry(source), TransferComparison.entry(destination), options: comparisonOptions)
                if status == .same { identicalItems += 1 } else { differentItems += 1 }
            }
        }
        let directory = st.st_mode & S_IFMT == S_IFDIR
        var bytes: Int64 = directory || st.st_mode & S_IFMT == S_IFLNK ? 0 : Int64(st.st_size)
        var files = directory ? 0 : 1
        if directory {
            directorySources.insert(url)
            progress.totalFolders += 1
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            childCounts[url] = children.count
            for child in children {
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
        let s = TreeMeasure.measure([url], followTopLevelLink: false, crossVolumes: true)?.bytes ?? 0
        sizes[url] = s
        return s
    }

}
