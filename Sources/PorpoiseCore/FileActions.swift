import Foundation

/// Small synchronous helpers for single-step operations.
extension FileActions {
    /// Creates a folder; "a/b" creates nested folders (Dolphin allows slashes).
    public static func makeFolder(named name: String, in folder: URL) throws -> URL {
        guard FileName.isValid(name, for: .multiComponent) else {
            throw FileOperationError.failed("“\(name)” is not a valid name.")
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    /// Reverts an undo record and returns the redo record. All or nothing: if a step fails, the steps
    /// already done are rolled back and the error is thrown, so the record stays valid for another try.
    public static func undo(_ record: UndoRecord, trash: ([URL]) throws -> [(original: URL, inTrash: URL)] = { try trashAll($0) }) throws
        -> UndoRecord?
    {
        switch record {
        case .cloud, .remote:
            // The service or the server undoes these (FileOperationsController asks it), never the file system.
            throw CocoaError(.featureUnsupported)
        case .created(let urls):
            // Items deleted since then have nothing left to undo.
            let trashed = try trash(urls.filter { FileJob.itemExists(at: $0) })
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
            for (original, inTrash) in trashed.reversed() { try? fm.moveItem(at: inTrash, to: original) }
            throw error
        }
        return trashed
    }
}
