import Foundation

/// Which files contain which trigrams (three consecutive bytes of their folded text), codesearch style: a query's
/// candidates are the files holding every trigram of the query, found by intersecting sorted posting lists. No false
/// negatives; candidates are confirmed by reading the file.
///
/// Built incrementally (`add`), then frozen into sorted keys and delta + varint encoded postings: a few bytes per
/// (file, trigram) pair.
public final class ContentIndex: @unchecked Sendable {
    private var building: [UInt32: [UInt32]] = [:]
    private var keys: [UInt32] = []
    /// Start of each key's postings in `postings`; one more than `keys` (the end).
    private var offsets: [UInt32] = [0]
    private var postings: [UInt8] = []
    private let lock = NSLock()

    public init() {}

    /// Whether anything was added.
    public var isEmpty: Bool { lock.withLock { building.isEmpty && keys.isEmpty } }

    public var storageBytes: Int { lock.withLock { freeze(); return keys.count * 8 + postings.count } }

    /// The distinct trigrams of folded text (sorted).
    public static func trigrams(_ folded: UnsafeBufferPointer<UInt8>) -> [UInt32] {
        guard folded.count >= 3 else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(folded.count - 2)
        var g = UInt32(folded[0]) << 8 | UInt32(folded[1])
        for i in 2..<folded.count {
            g = (g << 8 | UInt32(folded[i])) & 0xFF_FFFF
            out.append(g)
        }
        out.sort()
        var w = 0
        for r in out.indices where r == 0 || out[r] != out[r - 1] {
            out[w] = out[r]
            w += 1
        }
        out.removeLast(out.count - w)
        return out
    }

    /// Records `id` (added in increasing order) as containing `grams`.
    public func add(_ id: UInt32, grams: [UInt32]) {
        lock.withLock {
            if !keys.isEmpty { thaw() }
            for g in grams { building[g, default: []].append(id) }
        }
    }

    /// Encodes what was added, so the first query doesn't pay for it.
    public func prepare() { lock.withLock { freeze() } }

    /// Ids of files that may contain the folded `needle`; nil when it is too short to say (under three bytes).
    public func candidates(_ needle: [UInt8]) -> [UInt32]? {
        let grams = needle.withUnsafeBufferPointer { Self.trigrams($0) }
        guard !grams.isEmpty else { return nil }
        return lock.withLock {
            freeze()
            var lists: [Range<Int>] = []
            for g in grams {
                guard let k = Self.find(g, in: keys) else { return [] }
                lists.append(Int(offsets[k])..<Int(offsets[k + 1]))
            }
            lists.sort { $0.count < $1.count }
            var result = decode(lists[0])
            for l in lists.dropFirst() where !result.isEmpty {
                let other = decode(l)
                var out: [UInt32] = []
                var j = 0
                for id in result {
                    while j < other.count && other[j] < id { j += 1 }
                    if j < other.count && other[j] == id { out.append(id) }
                }
                result = out
            }
            return result
        }
    }

    private static func find(_ g: UInt32, in keys: [UInt32]) -> Int? {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < g { lo = mid + 1 } else { hi = mid }
        }
        return lo < keys.count && keys[lo] == g ? lo : nil
    }

    private func decode(_ r: Range<Int>) -> [UInt32] {
        var out: [UInt32] = []
        var prev: UInt32 = 0, i = r.lowerBound
        while i < r.upperBound {
            var v: UInt32 = 0, shift: UInt32 = 0
            while true {
                let b = postings[i]
                i += 1
                v |= UInt32(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            prev = out.isEmpty ? v : prev &+ v
            out.append(prev)
        }
        return out
    }

    /// The building dictionary into sorted, encoded arrays (lock held).
    private func freeze() {
        guard !building.isEmpty else { return }
        if !keys.isEmpty { thaw() }
        keys = building.keys.sorted()
        offsets = [0]
        offsets.reserveCapacity(keys.count + 1)
        postings = []
        for k in keys {
            var prev: UInt32 = 0
            for (n, id) in building[k]!.enumerated() {
                var v = n == 0 ? id : id &- prev
                prev = id
                while v >= 0x80 {
                    postings.append(UInt8(v & 0x7F) | 0x80)
                    v >>= 7
                }
                postings.append(UInt8(v))
            }
            offsets.append(UInt32(postings.count))
        }
        building = [:]
    }

    /// Frozen arrays back into the dictionary, to add more (lock held).
    private func thaw() {
        for (n, k) in keys.enumerated() { building[k, default: []].insert(contentsOf: decode(Int(offsets[n])..<Int(offsets[n + 1])), at: 0) }
        keys = []
        offsets = [0]
        postings = []
    }

    // MARK: Saving

    func encode(into d: inout Data) {
        lock.withLock {
            freeze()
            NameIndex.put(UInt64(keys.count), &d)
            NameIndex.put(UInt64(postings.count), &d)
            keys.withUnsafeBytes { d.append(contentsOf: $0) }
            offsets.withUnsafeBytes { d.append(contentsOf: $0) }
            d.append(contentsOf: postings)
        }
    }

    /// Reads what `encode` wrote at `at`; checks that every list lies inside the postings and keys ascend.
    static func decode(_ d: Data, at: inout Int, ids: Int) throws -> ContentIndex {
        let c = ContentIndex()
        let n = Int(try NameIndex.take(UInt64.self, d, &at)), bytes = Int(try NameIndex.take(UInt64.self, d, &at))
        guard n <= 1 << 24, bytes <= d.endIndex - at else { throw NameIndex.Corrupt.snapshot }
        c.keys = try NameIndex.take(UInt32.self, n, d, &at)
        c.offsets = try NameIndex.take(UInt32.self, n + 1, d, &at)
        c.postings = try NameIndex.take(UInt8.self, bytes, d, &at)
        guard c.offsets.first == 0, c.offsets.last.map(Int.init) == bytes else { throw NameIndex.Corrupt.snapshot }
        for i in 0..<n where c.offsets[i] > c.offsets[i + 1] || (i > 0 && c.keys[i] <= c.keys[i - 1]) { throw NameIndex.Corrupt.snapshot }
        guard bytes == 0 || c.postings.last! & 0x80 == 0 else { throw NameIndex.Corrupt.snapshot }
        _ = ids
        return c
    }
}
