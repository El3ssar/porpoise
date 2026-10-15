import Foundation
import Darwin

/// Immutable, concurrently searchable snapshot. Records refer to two UTF-8 names in a shared arena.
/// Paths are reconstructed only for hits; no URL, String, or stat allocation in the hot scan.
public struct NameIndex: @unchecked Sendable {
    public struct Record: Sendable {
        public var parent: UInt32
        public var nameOffset: UInt32
        public var foldedOffset: UInt32
        public var nameLength: UInt32
        public var foldedLength: UInt32
        public var flags: UInt32
        public var size: Int64
        public var modified: Double
        public var bloom0: UInt64 = 0
        public var bloom1: UInt64 = 0
        public var bloom2: UInt64 = 0
        public var bloom3: UInt64 = 0
        public var isDirectory: Bool { flags & 1 != 0 }
        public var hasContent: Bool { flags & 4 != 0 }
    }
    public private(set) var records: [Record] = []
    public private(set) var arena = Data()
    public static let noParent = UInt32.max
    public init() {}
    public var count: Int { records.count }
    public var storageBytes: Int { records.count * MemoryLayout<Record>.stride + arena.count }

    @discardableResult
    public mutating func append(name: String, parent: UInt32 = noParent, directory: Bool = false, symlink: Bool = false,
                                size: Int64 = 0, modified: Double = 0, content: String? = nil) -> UInt32 {
        let original = Array(name.utf8), folded = Array(IndexQuery.fold(name).utf8)
        precondition(records.count < Int(UInt32.max) && arena.count + original.count + folded.count < Int(UInt32.max))
        let a = UInt32(arena.count); arena.append(contentsOf: original)
        let b = UInt32(arena.count); arena.append(contentsOf: folded)
        var r = Record(parent: parent, nameOffset: a, foldedOffset: b, nameLength: UInt32(original.count),
                       foldedLength: UInt32(folded.count), flags: (directory ? 1 : 0) | (symlink ? 2 : 0), size: size, modified: modified)
        if let content {
            r.flags |= 4
            let bloom = Self.bloom(IndexQuery.fold(content))
            r.bloom0 = bloom.0; r.bloom1 = bloom.1; r.bloom2 = bloom.2; r.bloom3 = bloom.3
        }
        records.append(r)
        return UInt32(records.count - 1)
    }

    public func name(_ id: Int) -> String {
        let r = records[id]
        return String(decoding: arena[Int(r.nameOffset)..<Int(r.nameOffset + r.nameLength)], as: UTF8.self)
    }
    public func path(_ id: Int) -> String {
        var parts: [String] = [], next = UInt32(id)
        repeat {
            let r = records[Int(next)]; parts.append(name(Int(next))); next = r.parent
        } while next != Self.noParent
        return parts.reversed().joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }
    /// A crawl is depth-first, so each subtree occupies one contiguous range.
    public func countUnderPath(_ path: String) -> Int {
        guard count > 0 else { return 0 }
        let query = IndexQuery(literal: (path as NSString).lastPathComponent)
        guard let id = search(query, limit: Int.max).first(where: { self.path($0) == path }) else { return 0 }
        var end = id + 1
        while end < count && records[end].parent != Self.noParent && records[end].parent >= UInt32(id) { end += 1 }
        return end - id
    }
    public static func contains(path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Returns ids in stable crawl order. Limit applies after scope/filter checks, cancellation every 1024 rows.
    public func search(_ query: IndexQuery, scope: String? = nil, limit: Int = 5000, excluding: [String] = [],
                       cancelled: () -> Bool = { false }) -> [Int] {
        guard limit > 0 else { return [] }
        let terms = query.terms.map { Array($0.utf8) }
        var found: [Int] = []
        arena.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for i in records.indices {
                if i & 1023 == 0 && cancelled() { return }
                let r = records[i]
                if let dir = query.directory, dir != r.isDirectory { continue }
                if let min = query.minimumSize, r.size < min { continue }
                if let max = query.maximumSize, r.size > max { continue }
                if let after = query.after, r.modified < after { continue }
                if let before = query.before, r.modified >= before { continue }
                let start = base.advanced(by: Int(r.foldedOffset)), length = Int(r.foldedLength)
                var hit = true
                for term in terms {
                    if term.isEmpty { continue }
                    let matches = term.withUnsafeBytes { needle in memmem(start, length, needle.baseAddress!, needle.count) != nil }
                    if !matches { hit = false; break }
                }
                if !hit { continue }
                if !query.extensions.isEmpty {
                    let n = String(decoding: UnsafeRawBufferPointer(start: start, count: length), as: UTF8.self)
                    if r.isDirectory || !query.extensions.contains((n as NSString).pathExtension) { continue }
                }
                if let regex = query.regex {
                    let n = IndexQuery.fold(name(i))
                    if regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) == nil { continue }
                }
                if scope != nil || !query.paths.isEmpty || !excluding.isEmpty {
                    let p = path(i)
                    if excluding.contains(where: { Self.contains(path: p, in: $0) }) { continue }
                    if let scope, !Self.contains(path: p, in: scope) { continue }
                    let folded = IndexQuery.fold(p)
                    if !query.paths.allSatisfy({ folded.contains($0) }) { continue }
                }
                found.append(i)
                if found.count == limit { break }
            }
        }
        return found
    }

    /// A fixed-size trigram Bloom filter. False positives are verified against the current file; no false negatives.
    public static func bloom(_ text: String) -> (UInt64, UInt64, UInt64, UInt64) {
        let bytes = Array(text.utf8)
        var words = [UInt64](repeating: 0, count: 4)
        if bytes.count >= 3 {
            for i in 0..<(bytes.count - 2) {
                let gram = UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16
                let h = Int((gram &* 2654435761) >> 24)
                words[h >> 6] |= UInt64(1) << (h & 63)
            }
        }
        return (words[0], words[1], words[2], words[3])
    }
    public func contentCandidates(_ text: String, scope: String, cancelled: () -> Bool = { false }) -> [Int] {
        let b = Self.bloom(IndexQuery.fold(text))
        var result: [Int] = []
        for i in records.indices {
            if i & 1023 == 0 && cancelled() { return [] }
            let r = records[i]
            guard !r.isDirectory, r.flags & 2 == 0 else { continue }
            // Unindexed types and larger files must still be checked to preserve fallback semantics.
            if !r.hasContent || (r.bloom0 & b.0 == b.0 && r.bloom1 & b.1 == b.1 && r.bloom2 & b.2 == b.2 && r.bloom3 & b.3 == b.3) {
                if Self.contains(path: path(i), in: scope) { result.append(i) }
            }
        }
        return result
    }

    public func encoded() -> Data {
        var data = Data("PORPIDX1".utf8)
        for value in [UInt64(records.count), UInt64(arena.count)] {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        records.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(arena)
        return data
    }
    public enum Corrupt: Error { case snapshot }
    /// Data may be memory mapped. Validate every range and parent before exposing it to the scanner.
    public init(encoded data: Data) throws {
        guard data.count >= 24, data.prefix(8) == Data("PORPIDX1".utf8) else { throw Corrupt.snapshot }
        let count = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        let size = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)) }
        guard count <= UInt64((data.count - 24) / MemoryLayout<Record>.stride), size <= UInt64(data.count - 24) else { throw Corrupt.snapshot }
        let end = 24 + Int(count) * MemoryLayout<Record>.stride
        guard UInt64(data.count - end) == size else { throw Corrupt.snapshot }
        records = data.withUnsafeBytes { bytes in
            (0..<Int(count)).map { bytes.loadUnaligned(fromByteOffset: 24 + $0 * MemoryLayout<Record>.stride, as: Record.self) }
        }
        arena = data.subdata(in: end..<data.count)
        for (i, r) in records.enumerated() {
            guard (r.parent == Self.noParent || Int(r.parent) < i),
                UInt64(r.nameOffset) + UInt64(r.nameLength) <= size,
                UInt64(r.foldedOffset) + UInt64(r.foldedLength) <= size else { throw Corrupt.snapshot }
        }
    }
}
