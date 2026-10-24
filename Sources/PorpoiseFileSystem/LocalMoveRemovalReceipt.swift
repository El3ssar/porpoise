import Darwin
import Foundation
import PorpoiseCore

/// Captures metadata before copying, without reading file contents. Once the source is privately
/// claimed, both copies are hashed once. Deletion never repeats whole-subtree content scans.
public struct LocalMoveRemovalReceipt {
    public enum Checkpoint {
        /// Persist the holding directory identity BEFORE rename, then persist verification BEFORE unlink.
        case claimed(holding: URL, source: URL, target: URL?, verified: Bool)
        /// Deletion has committed; a late Stop finishes this item before stopping the batch.
        case deleting(holding: URL)
        case finished(holding: URL)
    }
    private struct Entry {
        let info: stat
        let contents: String
        func sameGeneration(as other: Entry, renamed: Bool = false) -> Bool {
            info.st_dev == other.info.st_dev && info.st_ino == other.info.st_ino
                && info.st_mode == other.info.st_mode && info.st_size == other.info.st_size
                && info.st_mtimespec.tv_sec == other.info.st_mtimespec.tv_sec
                && info.st_mtimespec.tv_nsec == other.info.st_mtimespec.tv_nsec
                && (renamed
                    || (info.st_ctimespec.tv_sec == other.info.st_ctimespec.tv_sec
                        && info.st_ctimespec.tv_nsec == other.info.st_ctimespec.tv_nsec))
        }
        var directory: Bool { info.st_mode & S_IFMT == S_IFDIR }
    }
    private let source: URL
    private let entries: [String: Entry]
    private let cancellation: DiskCancellation
    private let onRead: (Int64) -> Void
    private let onCheckpoint: (Checkpoint) throws -> Void

    public init(
        source: URL, directoryOnly: Bool = false, cancellation: DiskCancellation = DiskCancellation(),
        onRead: @escaping (Int64) -> Void = { _ in }, onCheckpoint: @escaping (Checkpoint) throws -> Void = { _ in }
    ) throws {
        self.source = source; self.cancellation = cancellation; self.onRead = onRead; self.onCheckpoint = onCheckpoint
        entries = try Self.scan(source, recursive: !directoryOnly, hashing: false, cancellation: cancellation, onRead: onRead)
    }

    public func verifyCopy(_ target: URL) throws {
        let current = try scan(source)
        guard matches(current) else { throw failure }
        try verifyCopy(target, against: current)
    }

    private func verifyCopy(_ target: URL, against original: [String: Entry]) throws {
        let copied = try scan(target, original: original)
        guard original.mapValues(\.contents) == copied.mapValues(\.contents) else { throw failure }
    }

    public func removeSource(afterVerifying target: URL) throws {
        try removeSource(target: target) { claimed in
            let copied = try scan(target, original: claimed)
            guard claimed.mapValues(\.contents) == copied.mapValues(\.contents) else { throw failure }
            return { path in
                guard let expected = copied[path], let actual = try? Self.entry(at: Self.url(target, path)),
                    expected.sameGeneration(as: actual)
                else { throw failure }
            }
        }
    }

    /// Only for a regular-file upload whose published bytes were independently verified by SHA-256.
    /// The caller must never substitute size/date or an unverified provider response for that digest.
    public func removeSource(afterVerifyingDigest digest: String, target: URL) throws {
        try removeSource(target: target) { claimed in
            guard claimed.count == 1, claimed[""]?.contents == "file:" + digest else { throw failure }
            return { _ in }
        }
    }

    private func removeSource(target: URL, validate: ([String: Entry]) throws -> (String) throws -> Void) throws {
        let current = try Self.scan(source, hashing: false, cancellation: cancellation, onRead: onRead)
        guard matches(current) else { throw failure }
        let holding = source.deletingLastPathComponent().appendingPathComponent(".porpoise-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { _ = rmdir(holding.path) }
        let claimed = holding.appendingPathComponent(source.lastPathComponent)
        try onCheckpoint(.claimed(holding: holding, source: source, target: target, verified: false))
        guard renamex_np(source.path, claimed.path, UInt32(RENAME_EXCL)) == 0 else {
            try? onCheckpoint(.finished(holding: holding))
            throw Self.posix()
        }
        var deleting = false
        do {
            try onCheckpoint(.claimed(holding: holding, source: source, target: target, verified: false))
            let captured = try scan(claimed)
            guard matches(captured, renamed: true) else { throw failure }
            let checkTarget = try validate(captured)
            // No bytes have been removed at any cancellable checkpoint. Stop here restores the
            // complete source. Once unlink starts, finish this item before observing a late Stop.
            try onCheckpoint(.claimed(holding: holding, source: source, target: target, verified: true))
            try cancellation.check()
            deleting = true
            try deleteClaimed(claimed, path: "", entries: captured, holding: holding, checkTarget: checkTarget)
        } catch {
            if deleting {
                throw FileOperationError.failed("Copy published; remaining source retained at “\(holding.path)”. \(error.localizedDescription)")
            }
            if renamex_np(claimed.path, source.path, UInt32(RENAME_EXCL)) != 0 {
                throw FileOperationError.failed("Copy published; source retained at “\(claimed.path)”. \(error.localizedDescription)")
            }
            if rmdir(holding.path) == 0 { try? onCheckpoint(.finished(holding: holding)) }
            throw error
        }
        guard rmdir(holding.path) == 0 else {
            throw FileOperationError.failed("Copy published; source remnants retained at “\(holding.path)”.")
        }
        try? onCheckpoint(.finished(holding: holding))
    }

    private func deleteClaimed(
        _ url: URL, path: String, entries captured: [String: Entry], holding: URL, renamedEntry: Entry? = nil,
        checkTarget: (String) throws -> Void
    ) throws {
        guard let expected = renamedEntry ?? captured[path], let actual = try? Self.entry(at: url),
            expected.sameGeneration(as: actual)
        else { throw failure }
        try checkTarget(path)
        if expected.directory {
            let names = try CopyVerification.directoryNames(url.path)
            for name in names {
                let childPath = path + "/" + name
                let child = url.appendingPathComponent(name)
                guard let childExpected = captured[childPath],
                    childExpected.sameGeneration(as: try Self.entry(at: child))
                else { throw failure }
                let owned = holding.appendingPathComponent(UUID().uuidString)
                guard renamex_np(child.path, owned.path, UInt32(RENAME_EXCL)) == 0 else { throw Self.posix() }
                do {
                    let renamed = try Self.entry(at: owned)
                    guard childExpected.sameGeneration(as: renamed, renamed: true) else { throw failure }
                    try deleteClaimed(
                        owned, path: childPath, entries: captured, holding: holding,
                        renamedEntry: Entry(info: renamed.info, contents: childExpected.contents), checkTarget: checkTarget)
                } catch {
                    if renamex_np(owned.path, child.path, UInt32(RENAME_EXCL)) != 0 {
                        throw FileOperationError.failed("Copy published; source retained at “\(owned.path)”. \(error.localizedDescription)")
                    }
                    throw error
                }
            }
            guard rmdir(url.path) == 0 else { throw failure }
        } else {
            try onCheckpoint(.deleting(holding: holding))
            guard unlink(url.path) == 0 else { throw Self.posix() }
        }
    }

    private func matches(_ current: [String: Entry], renamed: Bool = false) -> Bool {
        entries.count == current.count
            && entries.allSatisfy { path, expected in
                guard let actual = current[path] else { return false }
                return expected.sameGeneration(as: actual, renamed: renamed && path.isEmpty)
            }
    }

    public func verifyDirectoryIdentity() throws {
        try cancellation.check()
        guard let expected = entries[""], let current = try? Self.entry(at: source),
            expected.info.st_dev == current.info.st_dev, expected.info.st_ino == current.info.st_ino,
            expected.info.st_mode == current.info.st_mode
        else { throw failure }
    }

    public func removeEmptyDirectory() throws {
        try verifyDirectoryIdentity()
        guard let expected = entries[""] else { throw failure }
        let holding = source.deletingLastPathComponent().appendingPathComponent(".porpoise-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { _ = rmdir(holding.path) }
        let claimed = holding.appendingPathComponent(source.lastPathComponent)
        try onCheckpoint(.claimed(holding: holding, source: source, target: nil, verified: false))
        guard renamex_np(source.path, claimed.path, UInt32(RENAME_EXCL)) == 0 else { throw Self.posix() }
        let actual = try? Self.entry(at: claimed)
        guard actual?.info.st_dev == expected.info.st_dev, actual?.info.st_ino == expected.info.st_ino, rmdir(claimed.path) == 0 else {
            if renamex_np(claimed.path, source.path, UInt32(RENAME_EXCL)) != 0 {
                throw FileOperationError.failed("Copy published; source retained at “\(claimed.path)”.")
            }
            if rmdir(holding.path) == 0 { try? onCheckpoint(.finished(holding: holding)) }
            throw failure
        }
        if rmdir(holding.path) == 0 { try? onCheckpoint(.finished(holding: holding)) }
    }

    private var failure: FileOperationError {
        .failed("Copy published; source retained because its generation changed or the destination could not be verified.")
    }
    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func url(_ root: URL, _ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(String(path.dropFirst())) }
    private static func entry(at url: URL) throws -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix() }
        return Entry(info: info, contents: "")
    }
    private func scan(_ root: URL, original: [String: Entry]? = nil) throws -> [String: Entry] {
        try Self.scan(root, hashing: true, cancellation: cancellation, onRead: onRead, original: original)
    }
    private static func scan(
        _ root: URL, recursive: Bool = true, hashing: Bool, cancellation: DiskCancellation, onRead: (Int64) -> Void,
        original: [String: Entry]? = nil
    ) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        func walk(_ url: URL, _ path: String) throws {
            try cancellation.check()
            let before = try entry(at: url)
            let type = before.info.st_mode & S_IFMT
            let contents: String
            switch type {
            case S_IFDIR:
                contents = "directory"
                if recursive {
                    for name in try CopyVerification.directoryNames(url.path).sorted() {
                        let next = path + "/" + name
                        if let original, original[next] == nil, name.hasPrefix("._"),
                            original[path + "/" + name.dropFirst(2)] != nil,
                            CopyVerification.isGeneratedAppleDouble(url.appendingPathComponent(name))
                        {
                            continue
                        }
                        try autoreleasepool { try walk(url.appendingPathComponent(name), next) }
                    }
                }
            case S_IFREG:
                contents = hashing ? "file:" + (try CopyVerification.checkedDigest(url, cancellation: cancellation, onRead: onRead)) : "file"
            case S_IFLNK:
                contents = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            default:
                throw FileOperationError.failed(
                    "Cannot move “\(url.lastPathComponent)”: sockets, FIFOs and device files are not supported across volumes.")
            }
            let after = try entry(at: url)
            guard before.sameGeneration(as: after) else {
                throw FileOperationError.failed("Source changed while its generation was being read; source retained.")
            }
            result[path] = Entry(info: before.info, contents: contents)
        }
        try walk(root, "")
        return result
    }
}
