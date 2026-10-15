import CoreServices
import Foundation
import ImageIO
import PorpoiseCore
import UniformTypeIdentifiers

public struct BatchRenameSnapshot: Sendable {
    public let entries: [BatchRenameEntry]
    public let existing: [String: [String]]
    public let caseSensitive: [String: Bool]
    let identities: [String: BatchRenameIdentity]
}

struct BatchRenameIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(value.st_ino)
    }
}

public struct BatchRenameResult: Sendable {
    public let urls: [URL]
    public let undo: UndoRecord?
}

/// Directory snapshots and media metadata belong to Services; rules and collision planning stay pure in Core.
public enum BatchRenameService {
    public static func snapshot(_ urls: [URL], mediaMetadata: Bool = true) throws -> BatchRenameSnapshot {
        let fm = FileManager.default
        var entries: [BatchRenameEntry] = [], identities: [String: BatchRenameIdentity] = [:]
        var existing: [String: [String]] = [:], sensitive: [String: Bool] = [:]
        for source in urls {
            guard source.isFileURL else { throw BatchRenameError.invalid("Batch rename currently supports local files and folders.") }
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let url = parent.appendingPathComponent(source.lastPathComponent)
            identities[url.path] = try BatchRenameIdentity(url)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            let resources = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            var entry = BatchRenameEntry(
                url: url, isDirectory: isDirectory, created: resources.creationDate, modified: resources.contentModificationDate)
            if mediaMetadata, info.st_mode & S_IFMT == S_IFREG {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true { readImageMetadata(url, into: &entry) }
                if type?.conforms(to: .audio) == true, let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) {
                    if let authors = MDItemCopyAttribute(item, "kMDItemAuthors" as CFString) as? [String], !authors.isEmpty {
                        entry.metadata["artist"] = authors.joined(separator: ", ")
                    }
                    for (token, key) in [("album", "kMDItemAlbum"), ("title", "kMDItemTitle")] {
                        if let value = MDItemCopyAttribute(item, key as CFString) as? String { entry.metadata[token] = value }
                    }
                }
            }
            entries.append(entry)
            if existing[parent.path] == nil {
                existing[parent.path] = try fm.contentsOfDirectory(atPath: parent.path)
                sensitive[parent.path] =
                    (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
            }
        }
        return BatchRenameSnapshot(entries: entries, existing: existing, caseSensitive: sensitive, identities: identities)
    }

    public static func preview(_ snapshot: BatchRenameSnapshot, preset: BatchRenamePreset) -> BatchRenamePlan {
        BatchRename.plan(
            snapshot.entries, names: BatchRename.names(snapshot.entries, preset: preset), existing: snapshot.existing,
            caseSensitive: snapshot.caseSensitive)
    }

    public static func execute(_ plan: BatchRenamePlan, snapshot: BatchRenameSnapshot) throws -> BatchRenameResult {
        try execute(plan, snapshot: snapshot, move: moveExclusively)
    }

    /// Revalidates names and source identity immediately before moving. RENAME_EXCL closes target-creation races.
    static func execute(_ plan: BatchRenamePlan, snapshot: BatchRenameSnapshot, move: (URL, URL) throws -> Void) throws -> BatchRenameResult {
        guard plan.canApply, plan.rows.map(\.source) == snapshot.entries.map(\.url) else {
            throw BatchRenameError.invalid("Resolve every preview error before renaming.")
        }
        let current = try self.snapshot(snapshot.entries.map(\.url), mediaMetadata: false)
        guard current.identities == snapshot.identities else {
            throw BatchRenameError.invalid("A source item changed since the preview. Refresh the preview and try again.")
        }
        let checked = BatchRename.plan(
            current.entries, names: plan.rows.map { .success($0.proposedName) }, existing: current.existing, caseSensitive: current.caseSensitive)
        guard checked.canApply else { throw BatchRenameError.invalid(checked.rows.compactMap(\.problem).joined(separator: "\n")) }
        var completed: [RenameMove] = []
        do {
            for step in checked.steps {
                if let expected = snapshot.identities[step.from.path], try BatchRenameIdentity(step.from) != expected {
                    throw BatchRenameError.invalid("A source item changed during the batch: \(step.from.path)")
                }
                try move(step.from, step.to)
                completed.append(step)
            }
        } catch {
            var recovery: [String] = []
            for step in completed.reversed() {
                do { try moveExclusively(step.to, step.from) } catch {
                    recovery.append("\(step.to.path) → \(step.from.path): \(error.localizedDescription)")
                }
            }
            if !recovery.isEmpty {
                throw BatchRenameError.invalid(
                    "The batch stopped and some items could not be restored. No existing item was overwritten. Recovery paths:\n"
                        + recovery.joined(separator: "\n"))
            }
            throw error
        }
        return BatchRenameResult(urls: checked.rows.map(\.target), undo: completed.isEmpty ? nil : .batchRenamed(completed))
    }

    private static func moveExclusively(_ from: URL, _ to: URL) throws {
        let result = from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { target in renameatx_np(AT_FDCWD, source!, AT_FDCWD, target!, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func readImageMetadata(_ url: URL, into entry: inout BatchRenameEntry) {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any]
        else { return }
        if let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber { entry.metadata["width"] = width.stringValue }
        if let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber { entry.metadata["height"] = height.stringValue }
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any], let date = exif["DateTimeOriginal"] as? String {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
            let offset = exif["OffsetTimeOriginal"] as? String
            format.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
            entry.exifDate = format.date(from: date + (offset ?? ""))
        }
    }
}

extension FileOperationsController {
    /// Applies a batch as one undo item and announces all touched folders through the normal file-operation path.
    @discardableResult
    public func batchRename(_ plan: BatchRenamePlan, snapshot: BatchRenameSnapshot) throws -> [URL] {
        let result = try BatchRenameService.execute(plan, snapshot: snapshot)
        if let record = result.undo { pushUndo(record) }
        Self.notifyChanged(snapshot.entries.map(\.url) + result.urls)
        return result.urls
    }
}
