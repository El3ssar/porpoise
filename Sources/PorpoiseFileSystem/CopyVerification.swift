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
        public var ok: Bool { mismatches.isEmpty }
        public init() {}

        /// "Verified 12 files (3.4 MB): identical." or what differs.
        public var summary: String {
            let what = "\(files) \(files == 1 ? "file" : "files") (\(FileFormat.size(bytes)))"
            if ok { return "Verified \(what): identical to the originals." }
            let first = mismatches.prefix(3).map { ($0.path.isEmpty ? "" : $0.path + ": ") + $0.reason }.joined(separator: "; ")
            return "Verification found \(mismatches.count) \(mismatches.count == 1 ? "difference" : "differences") in \(what): \(first)"
        }
    }

    /// Compares `copy` with `original` (a file, or a folder with everything in it). Symlinks are compared by
    /// their target. `cancelled` is asked between files.
    public static func verify(_ original: URL, _ copy: URL, cancelled: () -> Bool = { false }) -> Result {
        var result = Result()
        compare(original, copy, path: "", into: &result, cancelled: cancelled)
        return result
    }

    private static func compare(_ a: URL, _ b: URL, path: String, into r: inout Result, cancelled: () -> Bool) {
        if cancelled() { return }
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0 else { return r.mismatches.append(.init(path: path, reason: "original is gone")) }
        guard lstat(b.path, &sb) == 0 else { return r.mismatches.append(.init(path: path, reason: "missing in the copy")) }
        let ta = sa.st_mode & S_IFMT, tb = sb.st_mode & S_IFMT
        guard ta == tb else { return r.mismatches.append(.init(path: path, reason: "a different kind of item")) }
        switch ta {
        case S_IFDIR:
            let fm = FileManager.default
            let ca = Set((try? fm.contentsOfDirectory(atPath: a.path)) ?? []), cb = Set((try? fm.contentsOfDirectory(atPath: b.path)) ?? [])
            for n in ca.subtracting(cb).sorted() { r.mismatches.append(.init(path: join(path, n), reason: "missing in the copy")) }
            for n in cb.subtracting(ca).sorted() { r.mismatches.append(.init(path: join(path, n), reason: "not in the original")) }
            for n in ca.intersection(cb).sorted() {
                compare(a.appendingPathComponent(n), b.appendingPathComponent(n), path: join(path, n), into: &r, cancelled: cancelled)
            }
        case S_IFLNK:
            let la = try? FileManager.default.destinationOfSymbolicLink(atPath: a.path)
            let lb = try? FileManager.default.destinationOfSymbolicLink(atPath: b.path)
            if la != lb { r.mismatches.append(.init(path: path, reason: "the link points elsewhere")) }
        case S_IFREG:
            r.files += 1
            r.bytes += Int64(sa.st_size)
            guard sa.st_size == sb.st_size else {
                return r.mismatches.append(
                    .init(path: path, reason: "\(FileFormat.size(Int64(sb.st_size))) instead of \(FileFormat.size(Int64(sa.st_size)))"))
            }
            guard let da = digest(a), let db = digest(b) else { return r.mismatches.append(.init(path: path, reason: "could not be read")) }
            if da != db { r.mismatches.append(.init(path: path, reason: "different contents (SHA-256)")) }
        default:
            break
        }
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

    /// SHA-256 of a file, read in 1 MB pieces.
    static func digest(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = ChecksumHasher(.sha256)
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
        return hasher.finalize()
    }
}
