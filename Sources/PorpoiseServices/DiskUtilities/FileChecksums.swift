import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem

public enum FileChecksumError: Error, LocalizedError {
    case changed(String), notRegular(String), unsafeReview, noKeeper, notDownloaded(String)
    public var errorDescription: String? {
        switch self {
        case .changed(let p): return "File changed while reading: \(p)";
        case .notRegular(let p): return "Not a physical regular file: \(p)";
        case .unsafeReview: return "Duplicate files changed since scanning. Scan again before moving them to the Trash.";
        case .noKeeper: return "Keep at least one file in every duplicate group."
        case .notDownloaded(let p): return "Not downloaded (stored only in the cloud), so not read: \(p)"
        }
    }
}
public enum FileChecksums {
    public static func digest(
        _ url: URL, algorithm: ChecksumAlgorithm = .sha256, partial: Bool = false,
        expected: DiskEntry? = nil, cancellation: DiskCancellation = DiskCancellation(),
        progress: (Int64) -> Void = { _ in }
    ) throws -> String {
        try cancellation.check()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw FileChecksumError.notRegular(url.path) }
        // iCloud and File Provider files kept only in the cloud (SF_DATALESS): reading would download them, gigabytes
        // for a duplicate search over a cloud folder.
        if before.st_flags & 0x4000_0000 != 0 { throw FileChecksumError.notDownloaded(url.path) }
        if let expected {
            guard expected.identity == DiskIdentity(device: before.st_dev, inode: UInt64(before.st_ino)), expected.size == before.st_size,
                abs(expected.modified.timeIntervalSince1970 - (Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9))
                    < 0.000001
            else { throw FileChecksumError.changed(url.path) }
        }
        var hash = ChecksumHasher(algorithm), total: Int64 = 0
        func read(_ count: Int) throws -> Int {
            try cancellation.check()
            let data = try handle.read(upToCount: count) ?? Data()
            hash.update(data); total += Int64(data.count); progress(total)
            return data.count
        }
        func readExactly(_ count: Int64) throws {
            var remaining = count
            while remaining > 0 {
                let n = try read(Int(min(256 * 1024, remaining)))
                guard n > 0 else { throw FileChecksumError.changed(url.path) }
                remaining -= Int64(n)
            }
        }
        if partial && before.st_size > 128 * 1024 {
            try readExactly(64 * 1024)
            try handle.seek(toOffset: UInt64(before.st_size - 64 * 1024)); try readExactly(64 * 1024)
        } else {
            // Read the initial length only: a continuously growing file must not turn this into an endless job.
            try readExactly(Int64(before.st_size))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw FileChecksumError.changed(url.path) }
        return hash.finalize()
    }
    public static func loadManifest(_ url: URL) throws -> [ChecksumEntry] {
        guard let text = IndexFileText.read(url.path, limit: 16 * 1024 * 1024) else { throw CocoaError(.fileReadCorruptFile) }
        return try ChecksumManifest.parse(text)
    }
    public struct Verification: Sendable {
        public let entry: ChecksumEntry
        public let matches: Bool
        public let actual: String?
        public let error: String?
    }
    public static func verify(
        _ entries: [ChecksumEntry], below root: URL, cancellation: DiskCancellation = DiskCancellation(),
        progress: (DiskProgress) -> Void = { _ in }
    ) throws -> [Verification] {
        var result: [Verification] = []
        for (i, entry) in entries.enumerated() {
            try cancellation.check()
            do {
                let url = try ChecksumManifest.resolve(entry, below: root)
                let actual = try digest(url, algorithm: entry.algorithm, cancellation: cancellation)
                result.append(Verification(entry: entry, matches: actual == entry.digest, actual: actual, error: nil))
            } catch is CancellationError { throw CancellationError() } catch {
                result.append(Verification(entry: entry, matches: false, actual: nil, error: error.localizedDescription))
            }
            progress(DiskProgress(files: i + 1, path: entry.path))
        }
        return result
    }
}

public enum CloneIdentity {
    /// APFS clone family id, when the filesystem supplies it. Unsupported is unknown, never inferred from hashes.
    public static func read(_ url: URL) -> UInt64? {
        var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS); attrs.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var data = [UInt8](repeating: 0, count: 64)
        let ok = data.withUnsafeMutableBytes {
            getattrlist(url.path, &attrs, $0.baseAddress!, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard ok == 0 else { return nil }
        return data.withUnsafeBytes { buffer in
            let length = buffer.loadUnaligned(as: UInt32.self), returned = buffer.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard length >= 32, returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 else { return nil }
            let value = buffer.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            return value == 0 ? nil : value
        }
    }
}
