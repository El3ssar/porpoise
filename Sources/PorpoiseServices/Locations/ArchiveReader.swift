import CLibArchive
import Darwin
import Foundation

/// Each pass owns its descriptor and libarchive reader. Opening a descriptor first prevents a replaced path
/// from silently switching the file under a pass; the version is checked again before publishing any result.
final class ArchiveReader {
    let handle: OpaquePointer
    let fd: Int32
    let version: ArchiveVersion

    init(_ url: URL) throws {
        guard url.isFileURL else { throw ArchiveFailure.invalid("Only local archives can be browsed.") }
        fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveFailure.invalid("The archive could not be opened.") }
        do { version = try ArchiveVersion(fd: fd) } catch { close(fd); throw error }
        guard let reader = archive_read_new() else { close(fd); throw ArchiveFailure.invalid("Could not create an archive reader.") }
        handle = reader
        archive_read_support_filter_all(reader)
        // ZIP's seekable reader uses its central directory, skipping multi-gigabyte bodies during listing.
        // Register it explicitly (format_all registers both streamable and seekable ZIP readers).
        archive_read_support_format_all(reader)
        archive_read_support_format_zip_seekable(reader)
        guard archive_read_open_fd(reader, fd, 64 * 1024) == 0 else {
            let reason = archive_error_string(reader).map { String(cString: $0) } ?? "Could not read the archive."
            // All stored properties are initialized: Swift invokes deinit on this throwing path.
            throw ArchiveFailure.invalid(reason)
        }
    }
    deinit { archive_read_free(handle); close(fd) }

    func next() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let result = archive_read_next_header(handle, &entry)
        if result == 1 { return nil }
        guard result == 0, let entry else { throw failure() }
        return entry
    }
    func skip() throws {
        guard archive_read_data_skip(handle) == 0 else { throw failure() }
    }
    func failure() -> ArchiveFailure {
        .invalid(archive_error_string(handle).map { String(cString: $0) } ?? "Could not read the archive.")
    }
    func unchanged(_ url: URL) throws {
        guard try ArchiveVersion(fd: fd) == version, ArchiveVersion.at(url) == version else { throw ArchiveFailure.changed }
    }
}

struct ArchiveVersion: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveFailure.invalid("The archive must be a regular local file.")
        }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    static func at(_ url: URL) -> Self? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return try? Self(fd: fd)
    }
    var cacheKey: String { "\(device)-\(inode)-\(size)-\(modifiedSeconds)-\(modifiedNanos)-\(changedSeconds)-\(changedNanos)" }
}

enum ArchiveFailure: LocalizedError {
    case invalid(String), changed, limit
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Could not browse this archive: \(reason)"
        case .changed: return "The archive changed. Refresh its contents and try again."
        case .limit: return "This archive exceeds Porpoise’s safety limits (size, compression ratio, entry count or path depth)."
        }
    }
}
