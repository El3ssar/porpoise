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
    case rename(String)
    case writeInto   // merge folders
    case cancel
}

public struct ConflictInfo: Sendable {
    public let source: FileItem
    public let destination: FileItem
    public let suggestedName: String
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
    case created([URL])                  // undo: trash these (copies, links, new folders/files)
    case moved([(from: URL, to: URL)])   // undo: move back
    case trashed([(original: URL, inTrash: URL)])
    case renamed(from: URL, to: URL)

    public var label: String {
        switch self {
        case .created: return "Create"
        case .moved: return "Move"
        case .trashed: return "Move to Trash"
        case .renamed: return "Rename"
        }
    }
}

/// Progress snapshot published by a running job.
public struct JobProgress: Sendable {
    public var kind: FileOperationKind
    public var totalBytes: Int64
    public var doneBytes: Int64
    public var totalItems: Int
    public var doneItems: Int
    public var currentName: String
    public var destination: URL?
    public init(kind: FileOperationKind, totalBytes: Int64, doneBytes: Int64, totalItems: Int, doneItems: Int, currentName: String, destination: URL?) {
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
    case intoItself(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .intoItself(let n): return "The folder “\(n)” cannot be copied or moved into itself."
        case .failed(let m): return m
        }
    }
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

    /// Minimum interval between progress callbacks.
    private static let publishInterval: TimeInterval = 0.05

    private let fm = FileManager.default
    private let lock = NSLock()
    private var _cancelled = false
    private var progress: JobProgress
    private var lastPublish = Date.distantPast
    private var sticky: ConflictResolution?
    private var created: [URL] = []
    private var moved: [(URL, URL)] = []
    private var trashed: [(URL, URL)] = []
    /// Byte counters for the file copyfile() is working on.
    private var currentFileBase: Int64 = 0
    private var currentFileCopied: Int64 = 0
    /// First error copyfile() reported through its callback during a recursive copy.
    fileprivate var copyFailure: (code: Int32, path: String?)?

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    public init(kind: FileOperationKind, sources: [URL], destinationFolder: URL? = nil) {
        self.kind = kind
        self.sources = sources
        self.destinationFolder = destinationFolder
        progress = JobProgress(kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0,
                               currentName: sources.first?.lastPathComponent ?? "", destination: destinationFolder)
    }

    /// Runs synchronously. Returns the undo record (nil if nothing happened).
    public func run() throws -> UndoRecord? {
        if kind == .copy || kind == .move {
            progress.totalBytes = sources.reduce(0) { $0 + Self.diskSize($1) }
        }
        publish(force: true)
        for src in sources {
            if isCancelled { break }
            progress.currentName = src.lastPathComponent
            do {
                try process(src)
            } catch FileOperationError.cancelled {
                break
            } catch {
                record(error, for: src, target: nil)
            }
            progress.doneItems += 1
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
            } catch where Self.isTrashUnsupportedError(error) {
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
        if force || now.timeIntervalSince(lastPublish) > Self.publishInterval {
            lastPublish = now
            onProgress(progress)
        }
    }

    // MARK: Transfer (copy / move / link)

    private enum Placement { case new, replace, merge }

    /// Copies/moves/links one item into `folder`, asking about conflicts. Returns the resulting URL
    /// (nil when skipped or denied).
    private func transfer(_ src: URL, into folder: URL) throws -> URL? {
        if isCancelled { throw FileOperationError.cancelled }
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
        } catch where Self.isPermissionError(error) {
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
            let srcItem = FileItem.load(src)
            let dstItem = FileItem.load(target)
            // A link to a folder is transferred as the link: there is nothing in it to merge.
            let srcIsFolder = (srcItem?.isBrowsableFolder ?? false) && !(srcItem?.isSymlink ?? false)
            let bothDirs = srcIsFolder && (dstItem?.isBrowsableFolder ?? false)
            let suggestion = FileFormat.suggestedName(for: src.lastPathComponent, existing: names(in: folder))
            let answer = conflictAnswer(srcItem, dstItem, bothDirs: bothDirs, suggestion: suggestion)
            switch answer {
            case .cancel:
                cancel()
                throw FileOperationError.cancelled
            case .skip:
                return skipped(src)
            case .rename(let name):
                guard FileActions.isValidName(name) else { throw FileOperationError.failed("“\(name)” is not a valid name.") }
                target = folder.appendingPathComponent(name)   // loop: the new name may exist too
            case .writeInto:
                return bothDirs ? (target, .merge) : skipped(src)
            case .overwriteIfOlder where !bothDirs:
                let sd = srcItem?.modificationDate ?? .distantPast
                let dd = dstItem?.modificationDate ?? .distantPast
                return sd > dd ? try replaceable(target, by: src) : skipped(src)
            case .overwrite, .overwriteIfOlder:
                return bothDirs ? (target, .merge) : try replaceable(target, by: src)
            }
        }
        return (target, .new)
    }

    private func conflictAnswer(_ src: FileItem?, _ dst: FileItem?, bothDirs: Bool, suggestion: String) -> ConflictResolution {
        // "Apply to All" answers stick, except Write Into, which only means something for two folders.
        if let s = sticky, !(s == .writeInto && !bothDirs) {
            if case .rename = s { return .rename(suggestion) }
            return s
        }
        guard let s = src, let d = dst else { return .skip }
        let a = resolveConflict(ConflictInfo(source: s, destination: d, suggestedName: suggestion))
        if a.applyToAll { sticky = a.resolution }
        return a.resolution
    }

    private func skipped(_ src: URL) -> (URL, Placement)? {
        progress.doneBytes += Self.diskSize(src)
        return nil
    }

    /// Overwriting a folder with something inside it would delete the source too.
    private func replaceable(_ target: URL, by src: URL) throws -> (URL, Placement) {
        if Self.isSameOrInside(src, target) {
            throw FileOperationError.failed("“\(target.lastPathComponent)” cannot be overwritten by an item inside it.")
        }
        return (target, .replace)
    }

    /// Writes `src` to `target`. When replacing, the new item is staged next to the target and renamed into place
    /// only once complete, so a failed copy never costs the existing file.
    private func place(_ src: URL, at target: URL, replacing: Bool) throws -> URL {
        let dest = replacing ? Self.stagingURL(for: target) : target
        var renamed = false
        switch kind {
        case .link:
            try fm.createSymbolicLink(at: dest, withDestinationURL: src)
        case .move where Self.sameVolume(src, target.deletingLastPathComponent()):
            try fm.moveItem(at: src, to: dest)
            renamed = true
            progress.doneBytes += Self.diskSize(dest)
        default:
            try copyRecursively(src, to: dest)
        }
        if replacing {
            // The new item is complete: now the old one may go, and the staged one takes its name
            // (a rename within one folder). replaceItemAt is avoided: it fails for items without read permission.
            do {
                try fm.removeItem(at: target)
                try fm.moveItem(at: dest, to: target)
            } catch {
                if renamed { try? fm.moveItem(at: dest, to: src) } else { try? fm.removeItem(at: dest) }
                throw error
            }
        }
        if kind == .move {
            // Cross-volume: the copy is complete, so the original can go now.
            if !renamed { try fm.removeItem(at: src) }
            moved.append((src, target))
        } else {
            created.append(target)
        }
        return target
    }

    /// "Write Into": transfers the children one by one; a failing child doesn't stop the others.
    private func merge(_ src: URL, into target: URL) throws {
        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        for child in children {
            do {
                _ = try transfer(child, into: target)
            } catch FileOperationError.cancelled {
                throw FileOperationError.cancelled
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
            if job.isCancelled { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR {
                // In recursive mode errors arrive here. Continuing after a content error would silently
                // skip the item and report an incomplete copy as done (a cross-volume move would then
                // delete the source). Metadata errors (xattrs, folder attributes on FAT/SMB) are tolerated.
                guard what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR || what == COPYFILE_RECURSE_ERROR
                        || what == COPYFILE_COPY_DATA else { return COPYFILE_CONTINUE }
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
            if isCancelled { throw FileOperationError.cancelled }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Could not copy “\(failed)”: \(String(cString: strerror(code)))",
            ])
        }
        // Clones report no data progress; account for the bytes anyway.
        let expected = Self.diskSize(src)
        if progress.doneBytes < currentFileBase + expected { progress.doneBytes = currentFileBase + expected }
        publish()
    }

    fileprivate func dataProgress(_ copied: Int64) {
        progress.doneBytes += max(0, copied - currentFileCopied)
        currentFileCopied = copied
        publish()
    }

    fileprivate func fileFinished() { currentFileCopied = 0 }

    // MARK: Helpers

    private func names(in folder: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Exists, including dangling symlinks (which `fileExists` reports as missing).
    public static func itemExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.containsScalar("/") && name != "." && name != ".." && !name.containsScalar("\0")
    }

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
