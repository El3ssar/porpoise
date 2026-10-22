import Darwin
import Foundation
import PorpoiseCore

/// Cheap rejection before loading display metadata or resolving package ancestry. This is the shared
/// predicate, with an equivalent ASCII name path; Unicode names and regular expressions still fold normally.
struct FolderSearchCandidates {
    let spec: SearchSpec
    private let asciiTerms: [[UInt8]]?

    init(spec: SearchSpec) {
        self.spec = spec
        asciiTerms =
            spec.query.regex == nil && spec.query.terms.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } }
            ? spec.query.terms.map { Array($0.utf8) } : nil
    }

    /// For an ASCII basename, folding is exactly ASCII case folding. Keep *every* non-ASCII basename
    /// as well: accented, decomposed and other Unicode spellings must reach the shared verifier.
    /// A required literal term is safe even when other terms or operators further restrict the query.
    var discoveryPattern: String {
        guard !spec.contents,
            let term = spec.query.terms.first(where: { !$0.isEmpty && !$0.contains("/") && $0.utf8.allSatisfy { $0 > 0 && $0 < 128 } })
        else { return "" }
        return "(?i:" + NSRegularExpression.escapedPattern(for: term) + ")|[^\\x00-\\x7F]"
    }

    func nameMatches(_ path: String) -> Bool {
        // fd terminates directory paths with a slash; NSString.lastPathComponent used to strip it.
        let trimmed = path.hasSuffix("/") ? path.dropLast() : path[...]
        let start = trimmed.lastIndex(of: "/").map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let name = trimmed[start...]
        guard let asciiTerms, name.utf8.allSatisfy({ $0 < 128 }) else { return spec.nameMatches(String(name)) }
        let bytes = name.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
        return asciiTerms.allSatisfy { term in
            if term.isEmpty { return false }  // String.contains("") is false in the shared Foundation predicate.
            guard bytes.count >= term.count else { return false }
            return (0...(bytes.count - term.count)).contains { start in
                term.indices.allSatisfy { bytes[start + $0] == term[$0] }
            }
        }
    }

    func firstLine(in path: String, isCancelled: () -> Bool = { false }) -> String? {
        guard let value = Self.read(path, limit: 5_000_000, isCancelled: isCancelled) else { return nil }
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { spec.contentMatches(String($0)) }).map(String.init)
    }

    /// The same physical-file/size/NUL/UTF-8 policy as IndexFileText, without FileHandle's repeated
    /// seek/stat/Objective-C allocation overhead for each tiny file. Read through EOF to detect growth,
    /// retaining the hard limit and checking cancellation between bounded chunks.
    private static func read(_ path: String, limit: Int, isCancelled: () -> Bool) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { return nil }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, Int(info.st_size) + 1))
        while true {
            if isCancelled() { return nil }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress!, min(bytes.count, limit + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return String(data: data, encoding: .utf8) }
            guard data.count + count <= limit else { return nil }
            let valid = buffer.withUnsafeBytes { bytes -> Bool in
                guard memchr(bytes.baseAddress!, 0, count) == nil else { return false }
                data.append(bytes.bindMemory(to: UInt8.self).baseAddress!, count: count)
                return true
            }
            if !valid { return nil }
            // A file that grew after fstat must not keep the tiny initial read size for its whole growth.
            if count == buffer.count && buffer.count < 64 * 1024 { buffer = [UInt8](repeating: 0, count: 64 * 1024) }
        }
    }
}
