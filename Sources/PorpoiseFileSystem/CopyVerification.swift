import Darwin
import Foundation
import PorpoiseCore

/// Checks a copy against its original after the fact: the same files, sizes and SHA-256 digests.
public enum CopyVerification {
    public struct Mismatch: Equatable, Sendable {
        /// Path inside the copied item ("" for the item itself).
        public var path: String
        public var reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public struct Result: Equatable, Sendable {
        public var files = 0
        public var bytes: Int64 = 0
        public var mismatches: [Mismatch] = []
        /// Stopped before everything was compared (cancelled): it proves nothing either way.
        public var incomplete = false
        /// Only a comparison that looked at everything, and found it identical, is a success.
        public var ok: Bool { mismatches.isEmpty && !incomplete }
        public init() {}

        /// "Verified 12 files (3.4 MB): identical." or what differs.
        public var summary: String {
            let what = "\(files) \(files == 1 ? "file" : "files") (\(FileFormat.size(bytes)))"
            if ok { return "Verified \(what): identical to the originals." }
            if mismatches.isEmpty { return "Verification stopped after \(what): not everything was compared." }
            let first = mismatches.prefix(3).map { ($0.path.isEmpty ? "" : $0.path + ": ") + $0.reason }.joined(separator: "; ")
            return "Verification found \(mismatches.count) \(mismatches.count == 1 ? "difference" : "differences") in \(what): \(first)"
        }
    }

    /// Compares `copy` with `original` (a file, or a folder with everything in it). Symlinks are compared by
    /// their target. `cancelled` is asked between files and read chunks; once it says yes the result is `incomplete`.
    /// A folder or link that can't be read is a mismatch, never an empty match.
    public static func verify(_ original: URL, _ copy: URL, cancelled: () -> Bool = { false }) -> Result {
        verify(original, copy, reader: Reader(), cancelled: cancelled)
    }

    /// How folders and links are read (tests put failures in).
    struct Reader {
        var list: (String) throws -> [String] = directoryNames
        var link: (String) throws -> String = { try FileManager.default.destinationOfSymbolicLink(atPath: $0) }
    }

    static func verify(_ original: URL, _ copy: URL, reader: Reader, cancelled: () -> Bool = { false }) -> Result {
        var result = Result()
        compare(original, copy, path: "", into: &result, reader: reader, cancelled: cancelled)
        return result
    }

    private static func compare(_ a: URL, _ b: URL, path: String, into r: inout Result, reader: Reader, cancelled: () -> Bool) {
        if cancelled() { return r.incomplete = true }
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0 else { return r.mismatches.append(.init(path: path, reason: "original is gone")) }
        guard lstat(b.path, &sb) == 0 else { return r.mismatches.append(.init(path: path, reason: "missing in the copy")) }
        let ta = sa.st_mode & S_IFMT, tb = sb.st_mode & S_IFMT
        guard ta == tb else { return r.mismatches.append(.init(path: path, reason: "a different kind of item")) }
        switch ta {
        case S_IFDIR:
            guard let la = try? reader.list(a.path) else { return r.mismatches.append(.init(path: path, reason: "the original could not be read")) }
            guard let lb = try? reader.list(b.path) else { return r.mismatches.append(.init(path: path, reason: "the copy could not be read")) }
            let ca = Set(contentNames(la, at: a))
            let cb = Set(lb).filter { name in
                ca.contains(name) || !name.hasPrefix("._") || !ca.contains(String(name.dropFirst(2)))
                    || !isGeneratedAppleDouble(b.appendingPathComponent(name))
            }
            for n in ca.subtracting(cb).sorted() { r.mismatches.append(.init(path: join(path, n), reason: "missing in the copy")) }
            for n in cb.subtracting(ca).sorted() { r.mismatches.append(.init(path: join(path, n), reason: "not in the original")) }
            for n in ca.intersection(cb).sorted() {
                autoreleasepool {
                    compare(
                        a.appendingPathComponent(n), b.appendingPathComponent(n), path: join(path, n), into: &r, reader: reader, cancelled: cancelled)
                }
            }
        case S_IFLNK:
            guard let la = try? reader.link(a.path), let lb = try? reader.link(b.path) else {
                return r.mismatches.append(.init(path: path, reason: "the link could not be read"))
            }
            if la != lb { r.mismatches.append(.init(path: path, reason: "the link points elsewhere")) }
        case S_IFREG:
            r.files += 1
            r.bytes += Int64(sa.st_size)
            guard sa.st_size == sb.st_size else {
                return r.mismatches.append(
                    .init(path: path, reason: "\(FileFormat.size(Int64(sb.st_size))) instead of \(FileFormat.size(Int64(sa.st_size)))"))
            }
            let da = digest(a, cancelled: cancelled), db = cancelled() ? nil : digest(b, cancelled: cancelled)
            if cancelled() { return r.incomplete = true }
            guard let da, let db else { return r.mismatches.append(.init(path: path, reason: "could not be read")) }
            if da != db { r.mismatches.append(.init(path: path, reason: "different contents (SHA-256)")) }
        default:
            r.mismatches.append(.init(path: path, reason: "unsupported filesystem item"))
        }
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

    /// Packed metadata on the source is unpacked by copyfile on a native destination. Unlinking its
    /// counterpart also removes it on FAT/exFAT; arbitrary ._ files remain ordinary captured entries.
    static func contentNames(_ names: [String], at folder: URL) -> [String] {
        let all = Set(names)
        return names.filter { name in
            !name.hasPrefix("._") || !all.contains(String(name.dropFirst(2))) || !isGeneratedAppleDouble(folder.appendingPathComponent(name))
        }
    }

    /// Foundation hides AppleDouble names, including ordinary user files named ._something.
    static func directoryNames(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Only metadata generated on a filesystem without native xattrs. A user file
    /// merely named ._something, an orphan, a symlink or malformed data must remain a real difference.
    static func isGeneratedAppleDouble(_ url: URL) -> Bool {
        var volume = statfs(), info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            statfs(url.path, &volume) == 0
        else { return false }
        let type = withUnsafeBytes(of: volume.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard type == "msdos" || type == "exfat" else { return false }
        return parsesAppleDouble(url, size: info.st_size)
    }

    static func parsesAppleDouble(_ url: URL, size: Int64) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var data = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &data, data.count)
        guard count >= 26 else { return false }
        func u16(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        func u32(_ at: Int) -> UInt64 {
            UInt64(data[at]) << 24 | UInt64(data[at + 1]) << 16 | UInt64(data[at + 2]) << 8 | UInt64(data[at + 3])
        }
        guard u32(0) == 0x00051607, u32(4) == 0x00020000 else { return false }
        let entries = u16(24), end = 26 + entries * 12
        guard entries > 0, end <= count else { return false }
        var ranges: [Range<UInt64>] = [], identifiers: Set<UInt64> = []
        for index in 0..<entries {
            let base = 26 + index * 12
            let id = u32(base), offset = u32(base + 4), length = u32(base + 8)
            guard id == 2 || id == 9, identifiers.insert(id).inserted,
                offset >= UInt64(end), offset + length <= UInt64(size)
            else { return false }
            let range = offset..<(offset + length)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { return false }
            ranges.append(range)
        }
        return true
    }

    /// Does not follow a replacement symlink or block if a regular file becomes a FIFO between stat/open.
    /// POSIX permission errors are preserved for the existing administrator retry path.
    static func checkedDigest(_ url: URL, cancellation: DiskCancellation, onRead: (Int64) -> Void = { _ in }) throws -> String {
        try cancellation.check()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.ENOTSUP) }
        var hasher = ChecksumHasher(.sha256)
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try cancellation.check()
            let count = read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(Data(bytes[0..<count]))
            onRead(Int64(count))
        }
        return hasher.finalize()
    }

    /// SHA-256 of a regular file, read in1MiB pieces. Public comparison reports unreadable as mismatch.
    static func digest(_ url: URL, cancelled: () -> Bool = { false }) -> String? {
        withoutActuallyEscaping(cancelled) { check in
            try? checkedDigest(url, cancellation: DiskCancellation(isCancelled: check))
        }
    }
}
