import Darwin
import Foundation

/// Publication primitives shared by local jobs and downloaded files.
public enum FilePublication {
    public enum Checkpoint {
        case protecting(holding: URL, original: URL, incoming: URL)
        case previousClaimed(holding: URL)
        case finished(holding: URL)
    }
    public struct Retained: LocalizedError {
        public let holding: URL
        public let incoming: URL
        public var errorDescription: String? {
            "The previous item is kept at “\(holding.path)”. The incoming item may remain at “\(incoming.path)”. Review both before retrying."
        }
    }
    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let type: mode_t
        let mode: mode_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posix() }
            device = info.st_dev; inode = info.st_ino; type = info.st_mode & S_IFMT
            mode = info.st_mode; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
        func sameAfterRename(_ other: Identity) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode && size == other.size
                && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
        }
    }
    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Some drivers ignore unsupported rename flags and still report success. Trust a native flag
    /// only when the volume explicitly advertises it; ENOTSUP remains a per-call fallback too.
    private static func supports(_ capability: UInt32, at url: URL) -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct Result {
            var length: UInt32 = 0
            var capabilities = vol_capabilities_attr_t()
        }
        var result = Result()
        guard getattrlist(url.path, &attributes, &result, MemoryLayout<Result>.size, 0) == 0 else { return false }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        return withUnsafeBytes(of: result.capabilities.valid) { valid in
            withUnsafeBytes(of: result.capabilities.capabilities) { available in
                valid.bindMemory(to: UInt32.self)[index] & capability != 0
                    && available.bindMemory(to: UInt32.self)[index] & capability != 0
            }
        }
    }

    public static func renameExclusively(_ source: URL, to target: URL) throws {
        try renameExclusively(source, to: target) { source, target in
            guard supports(UInt32(VOL_CAP_INT_RENAME_EXCL), at: target.deletingLastPathComponent()) else {
                errno = ENOTSUP; return -1
            }
            return renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
        }
    }

    /// Only ENOTSUP enters the compatibility path. Every other error preserves its original meaning.
    static func renameExclusively(
        _ source: URL, to target: URL, exclusive: (URL, URL) -> Int32,
        beforeReservedRename: () throws -> Void = {}
    ) throws {
        if exclusive(source, target) == 0 { return }
        let code = errno
        guard code == ENOTSUP else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let sourceIdentity = try Identity(source)
        let directory = sourceIdentity.type == S_IFDIR
        let descriptor: Int32
        if directory {
            guard mkdir(target.path, 0o700) == 0 else { throw posix() }
            descriptor = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw posix() }
        defer { close(descriptor) }
        var reservation = stat()
        guard fstat(descriptor, &reservation) == 0 else { throw posix() }
        var published = false
        defer {
            var current = stat()
            if !published, lstat(target.path, &current) == 0, current.st_dev == reservation.st_dev, current.st_ino == reservation.st_ino,
                directory || current.st_size == 0
            {
                if directory { _ = rmdir(target.path) } else { _ = unlink(target.path) }
            }
        }
        try beforeReservedRename()
        var current = stat()
        guard lstat(target.path, &current) == 0, current.st_dev == reservation.st_dev, current.st_ino == reservation.st_ino,
            current.st_mode & S_IFMT == reservation.st_mode & S_IFMT, directory || current.st_size == 0
        else { throw POSIXError(.EEXIST) }
        // The filesystem has no atomic exclusive rename. Reserving with mkdir/O_EXCL protects every
        // pre-existing name; a process replacing our reservation after this check remains a narrow race.
        guard rename(source.path, target.path) == 0 else { throw posix() }
        published = true
    }

    public static func replace(
        _ staged: URL, at target: URL, dispose: (URL) throws -> Void,
        checkpoint: (Checkpoint) throws -> Void = { _ in }
    ) throws {
        var incomingIdentity = try Identity(staged)
        let supported = supports(UInt32(VOL_CAP_INT_RENAME_SWAP), at: target.deletingLastPathComponent())
        if supported, renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
            guard let published = try? Identity(target), incomingIdentity.sameAfterRename(published) else {
                throw Retained(holding: staged, incoming: target)
            }
            incomingIdentity = published
            do { try dispose(staged) } catch {
                guard (try? Identity(target)) == incomingIdentity,
                    renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0
                else { throw Retained(holding: staged, incoming: target) }
                throw error
            }
            return
        }
        let code = supported ? errno : ENOTSUP
        guard code == ENOTSUP else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let holding = target.deletingLastPathComponent().appendingPathComponent(".porpoise-replaced-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let previousFolder = holding.appendingPathComponent("Previous")
        let incomingFolder = holding.appendingPathComponent("Incoming")
        let previous = previousFolder.appendingPathComponent(target.lastPathComponent)
        let incoming = incomingFolder.appendingPathComponent(target.lastPathComponent)
        var incomingClaimed = false, claimed = false, published = false
        do {
            try checkpoint(.protecting(holding: holding, original: target, incoming: staged))
            try FileManager.default.createDirectory(at: previousFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: incomingFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try renameExclusively(staged, to: incoming)
            incomingClaimed = true
            try checkpoint(.protecting(holding: holding, original: target, incoming: incoming))
            try renameExclusively(target, to: previous)
            claimed = true
            try checkpoint(.previousClaimed(holding: holding))
            try renameExclusively(incoming, to: target)
            published = true
            let placed = try Identity(target)
            guard incomingIdentity.sameAfterRename(placed) else { throw Retained(holding: holding, incoming: target) }
            incomingIdentity = placed
            try dispose(previous)
            guard rmdir(incomingFolder.path) == 0, rmdir(previousFolder.path) == 0 else { throw Retained(holding: holding, incoming: target) }
            guard rmdir(holding.path) == 0 else { throw Retained(holding: holding, incoming: target) }
        } catch {
            if error is Retained { throw error }
            do {
                if published {
                    guard try Identity(target) == incomingIdentity else { throw Retained(holding: holding, incoming: incoming) }
                    try renameExclusively(target, to: incoming)
                }
                if claimed { try renameExclusively(previous, to: target) }
                if incomingClaimed { try renameExclusively(incoming, to: staged) }
            } catch {
                throw Retained(holding: holding, incoming: incoming)
            }
            _ = rmdir(incomingFolder.path)
            _ = rmdir(previousFolder.path)
            if rmdir(holding.path) == 0 { try? checkpoint(.finished(holding: holding)) }
            throw error
        }
        try? checkpoint(.finished(holding: holding))
    }
}
