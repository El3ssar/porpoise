import Darwin
import Foundation
import PorpoiseCore

/// Small synchronous helpers for single-step operations.
extension FileActions {
    /// Creates a folder; "a/b" creates nested folders (Dolphin allows slashes).
    public static func makeFolder(named name: String, in folder: URL) throws -> URL {
        guard FileName.isValid(name, for: .multiComponent) else {
            throw FileOperationError.failed("“\(name)” is not a valid name.")
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        // Parents may be shared; ownership of the requested leaf must be established exclusively.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(url.path, 0o777) == 0 else {
            let code = errno
            if code == EEXIST { throw FileOperationError.failed("A file or folder named “\(url.lastPathComponent)” already exists.") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return url
    }

    /// Creates a file, failing (atomically, no race) if one with that name exists.
    public static func makeFile(named name: String, in folder: URL, contents: Data = Data()) throws -> URL {
        guard FileName.isValid(name, for: .local) else { throw FileOperationError.failed("“\(name)” is not a valid name.") }
        let url = folder.appendingPathComponent(name)
        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
            throw FileOperationError.failed("A file named “\(name)” already exists.")
        }
        return url
    }

    public static func rename(_ url: URL, to newName: String) throws -> URL {
        guard FileName.isValid(newName, for: .local) else { throw FileOperationError.failed("“\(newName)” is not a valid name.") }
        let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
        if dst.path == url.path { return url }
        // A case-only change ("a" → "A") is the same file on a case-insensitive volume.
        if FileJob.itemExists(at: dst) && dst.path.lowercased() != url.path.lowercased() {
            throw FileOperationError.failed("A file named “\(newName)” already exists.")
        }
        try FileManager.default.moveItem(at: url, to: dst)
        return dst
    }

    /// Validation message for a new name (KIO's folder dialog), nil when fine.
    public static func validateName(_ name: String, in folder: URL, allowSlash: Bool) -> (message: String, isError: Bool)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ("", true) }
        let problem = FileName.validate(name, for: allowSlash ? .multiComponent : .local)
        if let problem, problem.isError { return (problem.message(for: name), true) }
        // itemExists: a dangling symlink also takes the name.
        if FileJob.itemExists(at: folder.appendingPathComponent(name)) {
            return ("A file or folder with this name already exists.", true)
        }
        if let problem { return (problem.message(for: name), false) }
        return nil
    }

    /// A failed undo whose rollback could not restore every step. Only these reconciled records
    /// remain safe to offer; uncertain paths need manual inspection and are omitted from both.
    public struct PartialUndoError: LocalizedError {
        public let remaining: UndoRecord?
        public let inverse: UndoRecord?
        public let cause: any Error
        public let paths: [URL]
        public var errorDescription: String? {
            "The operation could not be fully restored: \(cause.localizedDescription)\nReview these locations before retrying:\n"
                + paths.map(\.path).joined(separator: "\n")
        }
    }

    /// Completed Trash moves that could not be restored after another move failed.
    public struct PartialTrashError: LocalizedError {
        public let retained: [(original: URL, inTrash: URL)]
        public let cause: any Error
        public var errorDescription: String? {
            "Some items remain in the Trash: \(cause.localizedDescription)\n"
                + retained.map { "\($0.original.path) → \($0.inTrash.path)" }.joined(separator: "\n")
        }
    }

    private struct MoveIdentity: Equatable {
        let device: Int32, inode: UInt64, mode: mode_t, size: Int64
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private struct IncompleteMoves: Error {
        let applied: Set<Int>
        let uncertain: Set<Int>
        let cause: any Error
        let paths: [URL]
    }

    /// Revert a record. Roll back earlier steps on failure, or report the exact recoverable
    /// subsets if rollback itself fails. Never restore an obsolete full record after a partial result.
    public static func undo(_ record: UndoRecord, trash: ([URL]) throws -> [(original: URL, inTrash: URL)] = { try trashAll($0) }) throws
        -> UndoRecord?
    {
        try undo(record, trash: trash, move: FileManager.default.moveItem)
    }

    /// Per-call injection lets fixtures interrupt real moves without global mutable test state.
    static func undo(
        _ record: UndoRecord, trash: ([URL]) throws -> [(original: URL, inTrash: URL)] = { try trashAll($0) },
        move: (URL, URL) throws -> Void
    ) throws -> UndoRecord? {
        do {
            switch record {
            case .cloud, .remote:
                throw CocoaError(.featureUnsupported)
            case .created(let urls):
                do {
                    let trashed = try trash(urls.filter { FileJob.itemExists(at: $0) })
                    return trashed.isEmpty ? nil : .trashed(trashed)
                } catch let error as PartialTrashError {
                    let retained = Set(error.retained.map(\.original))
                    let remaining = urls.filter { !retained.contains($0) }
                    throw PartialUndoError(
                        remaining: remaining.isEmpty ? nil : .created(remaining), inverse: .trashed(error.retained), cause: error,
                        paths: error.retained.flatMap { [$0.original, $0.inTrash] })
                }
            case .moved(let pairs):
                try moveAll(pairs.reversed().map { ($0.to, $0.from) }, using: move)
                return .moved(pairs.map { (from: $0.to, to: $0.from) })
            case .trashed(let pairs):
                try moveAll(pairs.reversed().map { ($0.inTrash, $0.original) }, using: move)
                return .moved(pairs.map { (from: $0.inTrash, to: $0.original) })
            case .renamed(let from, let to):
                try move(to, from)
                return .renamed(from: to, to: from)
            case .batchRenamed(let steps):
                let inverse = steps.reversed().map { RenameMove(from: $0.to, to: $0.from) }
                try moveAll(inverse.map { ($0.from, $0.to) }, using: move)
                return .batchRenamed(inverse)
            }
        } catch let error as IncompleteMoves {
            // moveAll executes in reverse record order. Preserve physical batch-rename order,
            // including temporary names, rather than grouping steps by URL.
            var remaining: UndoRecord?, inverse: UndoRecord?
            func pending(_ index: Int, _ count: Int) -> Bool {
                !error.applied.contains(count - 1 - index) && !error.uncertain.contains(count - 1 - index)
            }
            func applied(_ index: Int, _ count: Int) -> Bool { error.applied.contains(count - 1 - index) }
            switch record {
            case .moved(let pairs):
                let rest = pairs.enumerated().filter { pending($0.offset, pairs.count) }.map(\.element)
                let done = pairs.enumerated().filter { applied($0.offset, pairs.count) }.map { (from: $0.element.to, to: $0.element.from) }
                remaining = rest.isEmpty ? nil : .moved(rest)
                inverse = done.isEmpty ? nil : .moved(done)
            case .trashed(let pairs):
                let rest = pairs.enumerated().filter { pending($0.offset, pairs.count) }.map(\.element)
                let done = pairs.enumerated().filter { applied($0.offset, pairs.count) }.map { (from: $0.element.inTrash, to: $0.element.original) }
                remaining = rest.isEmpty ? nil : .trashed(rest)
                inverse = done.isEmpty ? nil : .moved(done)
            case .batchRenamed(let steps):
                let endpoints = steps.flatMap { [$0.from, $0.to] }.map { $0.standardizedFileURL.path.lowercased() }
                guard Set(endpoints).count == endpoints.count else {
                    // Temporary-name chains cannot be split into independent Undo and Redo records:
                    // completing either subset could invalidate the other's source paths.
                    throw PartialUndoError(
                        remaining: nil, inverse: nil, cause: error.cause, paths: steps.flatMap { [$0.from, $0.to] })
                }
                let rest = steps.enumerated().filter { pending($0.offset, steps.count) }.map(\.element)
                let done = steps.enumerated().filter { applied($0.offset, steps.count) }.map(\.element).reversed()
                    .map { RenameMove(from: $0.to, to: $0.from) }
                remaining = rest.isEmpty ? nil : .batchRenamed(rest)
                inverse = done.isEmpty ? nil : .batchRenamed(done)
            default: break
            }
            throw PartialUndoError(remaining: remaining, inverse: inverse, cause: error.cause, paths: error.paths)
        }
    }

    private static func moveAll(_ moves: [(URL, URL)], using move: (URL, URL) throws -> Void) throws {
        var done: [(index: Int, identity: MoveIdentity?)] = []
        var attempted: Int?
        var targetExisted = false, sourceExisted = false
        do {
            for (index, pair) in moves.enumerated() {
                try FileManager.default.createDirectory(at: pair.1.deletingLastPathComponent(), withIntermediateDirectories: true)
                attempted = index
                targetExisted = FileJob.itemExists(at: pair.1)
                sourceExisted = FileJob.itemExists(at: pair.0)
                try move(pair.0, pair.1)
                done.append((index, MoveIdentity(pair.1)))
                attempted = nil
            }
        } catch {
            let cause = error
            var uncertain = Set<Int>()
            // A cross-volume move can fail after copying or removing. Do not offer an automatic
            // retry for that step if its paths changed despite the thrown error.
            if let attempted {
                let pair = moves[attempted]
                if (sourceExisted && !FileJob.itemExists(at: pair.0)) || (!targetExisted && FileJob.itemExists(at: pair.1)) {
                    uncertain.insert(attempted)
                }
            }
            var applied = Set<Int>()
            for step in done.reversed() {
                let pair = moves[step.index]
                guard let identity = step.identity, MoveIdentity(pair.1) == identity else {
                    uncertain.insert(step.index)
                    continue
                }
                do { try move(pair.1, pair.0) } catch {
                    if MoveIdentity(pair.1) == identity {
                        applied.insert(step.index)
                    } else {
                        uncertain.insert(step.index)
                    }
                }
            }
            guard !applied.isEmpty || !uncertain.isEmpty else { throw cause }
            let paths = moves.enumerated().filter { applied.contains($0.offset) || uncertain.contains($0.offset) }
                .flatMap { [$0.element.0, $0.element.1] }
            throw IncompleteMoves(applied: applied, uncertain: uncertain, cause: cause, paths: paths)
        }
    }

    /// Platform primitive; Services injects its origin-recording TrashService into app jobs and Undo.
    public static func trashItem(_ url: URL) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    public static func trashAll(_ urls: [URL], using moveToTrash: (URL) throws -> URL? = trashItem) throws -> [(original: URL, inTrash: URL)] {
        let fm = FileManager.default
        var trashed: [(URL, URL)] = []
        do {
            for u in urls {
                if let out = try moveToTrash(u) { trashed.append((u, out)) }
            }
        } catch {
            let cause = error
            var retained: [(original: URL, inTrash: URL)] = []
            for (original, inTrash) in trashed.reversed() {
                do { try fm.moveItem(at: inTrash, to: original) } catch { retained.append((original, inTrash)) }
            }
            if !retained.isEmpty { throw PartialTrashError(retained: retained.reversed(), cause: cause) }
            throw cause
        }
        return trashed
    }
}
