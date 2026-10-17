import Darwin
import Foundation

/// Immutable, concurrently searchable snapshot, stored as columns: an entry is a number, its parent a smaller number,
/// its folded name a run of bytes in one arena (and the name as written in a second arena when it differs). About 25
/// bytes per entry plus its name; no object, String or URL per file.
///
/// Searches run on every core: a word is found by scanning the folded-names arena with memmem, a chunk per core,
/// and each hit checked against the rest of the query; queries without a word check every entry, a pass over flat
/// columns. Paths are reconstructed only for hits (`path`), and worked out once per query for path conditions.
public struct NameIndex: @unchecked Sendable {
    public static let noParent = UInt32.max
    /// `nameStarts` value of a name stored only folded (it was already lower-case ASCII).
    static let sameAsFolded = UInt32.max

    enum Flag {
        static let directory: UInt8 = 1
        static let symlink: UInt8 = 2
        /// The file's text is in `content`: it can be ruled out without reading it.
        static let content: UInt8 = 4
    }

    private(set) var parents: [UInt32] = []
    private(set) var foldedStarts: [UInt32] = []
    private(set) var nameStarts: [UInt32] = []
    private(set) var sizes: [Int64] = []
    /// Seconds since 1970.
    private(set) var mtimes: [UInt32] = []
    private(set) var flags: [UInt8] = []
    /// Folded names, each followed by a NUL. A root's is its last component only.
    private(set) var folded: [UInt8] = []
    /// Names as written, NUL-terminated, for those whose folded form differs (and roots: their whole path).
    private(set) var names: [UInt8] = []
    /// Roots: entries without a parent (named by their whole path).
    private(set) var roots: [UInt32] = []
    private(set) var content = ContentIndex()
    /// Paths already looked up in this snapshot (scopes, patches): one scan each.
    private var lookups = LookupCache()

    public init() {}

    public var count: Int { parents.count }
    public var storageBytes: Int {
        count * 25 + folded.count + names.count + (content.isEmpty ? 0 : content.storageBytes)
    }

    /// Adds an entry under `parent` (none: a root, named by its whole path). `content`: the file's text, indexed for
    /// `contentCandidates`.
    @discardableResult
    public mutating func append(
        name: String, parent: UInt32 = noParent, directory: Bool = false, symlink: Bool = false, size: Int64 = 0, modified: Double = 0,
        content text: String? = nil
    ) -> UInt32 {
        let isRoot = parent == Self.noParent
        let original = Array(name.utf8)
        let foldedName = Array(IndexQuery.fold(isRoot && name.hasPrefix("/") ? (name as NSString).lastPathComponent : name).utf8)
        var f: UInt8 = (directory ? Flag.directory : 0) | (symlink ? Flag.symlink : 0)
        var grams: [UInt32]?
        if let text {
            f |= Flag.content
            grams = Array(IndexQuery.fold(text).utf8).withUnsafeBufferPointer { ContentIndex.trigrams($0) }
        }
        return append(
            parent: parent, name: original, folded: !isRoot && original == foldedName ? nil : foldedName, size: size,
            mtime: UInt32(clamping: Int64(modified.isFinite ? modified : 0)), flags: f, grams: grams)
    }

    /// Adds an entry whose name is already folded (`folded` nil: the name is its own folded form). The crawler's way.
    @discardableResult
    public mutating func append(
        parent: UInt32, name: [UInt8], folded fname: [UInt8]?, size: Int64, mtime: UInt32, directory: Bool, symlink: Bool,
        contentGrams grams: [UInt32]?
    ) -> UInt32 {
        let f: UInt8 = (directory ? Flag.directory : 0) | (symlink ? Flag.symlink : 0) | (grams != nil ? Flag.content : 0)
        return append(parent: parent, name: name, folded: fname, size: size, mtime: mtime, flags: f, grams: grams)
    }

    private mutating func append(parent: UInt32, name: [UInt8], folded fname: [UInt8]?, size: Int64, mtime: UInt32, flags f: UInt8, grams: [UInt32]?)
        -> UInt32
    {
        precondition(parents.count < Int(UInt32.max) - 1 && folded.count + names.count + name.count * 2 < Int(UInt32.max) - 2)
        if !isKnownUniquelyReferenced(&lookups) { lookups = LookupCache() } else { lookups.clear() }
        let id = UInt32(parents.count)
        parents.append(parent)
        foldedStarts.append(UInt32(folded.count))
        if let fname {
            folded.append(contentsOf: fname)
            nameStarts.append(UInt32(names.count))
            names.append(contentsOf: name)
            names.append(0)
        } else {
            folded.append(contentsOf: name)
            nameStarts.append(Self.sameAsFolded)
        }
        folded.append(0)
        sizes.append(size)
        mtimes.append(mtime)
        flags.append(f)
        if parent == Self.noParent { roots.append(id) }
        if let grams {
            if !isKnownUniquelyReferenced(&content) { content = content.copy() }
            content.add(id, grams: grams)
        }
        return id
    }

    // MARK: Reading

    func foldedRange(_ id: Int) -> Range<Int> {
        let s = Int(foldedStarts[id])
        return s..<(id + 1 < count ? Int(foldedStarts[id + 1]) - 1 : folded.count - 1)
    }

    /// The name as written (a root's: its whole path).
    func storedName(_ id: Int) -> String {
        let s = nameStarts[id]
        guard s != Self.sameAsFolded else { return String(decoding: folded[foldedRange(id)], as: UTF8.self) }
        var e = Int(s)
        while names[e] != 0 { e += 1 }
        return String(decoding: names[Int(s)..<e], as: UTF8.self)
    }

    public func name(_ id: Int) -> String {
        let value = storedName(id)
        return parents[id] == Self.noParent && value.hasPrefix("/") ? (value as NSString).lastPathComponent : value
    }

    public func isDirectory(_ id: Int) -> Bool { flags[id] & Flag.directory != 0 }
    public func isSymlink(_ id: Int) -> Bool { flags[id] & Flag.symlink != 0 }
    public func size(_ id: Int) -> Int64 { sizes[id] }
    public func modified(_ id: Int) -> Double { Double(mtimes[id]) }

    public func path(_ id: Int) -> String {
        var parts: [String] = []
        var next = UInt32(id)
        repeat {
            parts.append(storedName(Int(next)))
            next = parents[Int(next)]
        } while next != Self.noParent
        return parts.reversed().joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// The entry at `path` (a root's path or below one), if indexed.
    public func id(of path: String) -> Int? {
        if let known = lookups.get(path) { return known }
        var found: Int?
        for r in roots {
            let rp = storedName(Int(r))
            guard FilePath.contains(path: path, in: rp) else { continue }
            var cur = Int(r)
            var ok = true
            for comp in path.dropFirst(rp.count).split(separator: "/") {
                let want = Array(comp.utf8)
                // Children come after their parent: scan forward for one with this name.
                var hit: Int?
                parents.withUnsafeBufferPointer { par in
                    var j = cur + 1
                    while j < par.count {
                        if par[j] == UInt32(cur), nameBytesEqual(j, want) {
                            hit = j
                            break
                        }
                        j += 1
                    }
                }
                guard let h = hit else {
                    ok = false
                    break
                }
                cur = h
            }
            if ok {
                found = cur
                break
            }
        }
        lookups.set(path, found)
        return found
    }

    private func nameBytesEqual(_ id: Int, _ want: [UInt8]) -> Bool {
        let s = nameStarts[id]
        if s == Self.sameAsFolded {
            let r = foldedRange(id)
            return r.count == want.count && folded[r].elementsEqual(want)
        }
        var e = Int(s)
        while names[e] != 0 { e += 1 }
        return e - Int(s) == want.count && names[Int(s)..<e].elementsEqual(want)
    }

    /// 1 for `id` and the entries below it (one pass forward: parents come before their children).
    func subtreeMap(_ ids: [Int]) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: count)
        guard let first = ids.min() else { return m }
        for i in ids { m[i] = 1 }
        parents.withUnsafeBufferPointer { par in
            m.withUnsafeMutableBufferPointer { mm in
                for i in (first + 1)..<max(first + 1, par.count) where mm[i] == 0 {
                    let p = par[i]
                    if p != Self.noParent && mm[Int(p)] == 1 { mm[i] = 1 }
                }
            }
        }
        return m
    }

    /// The number of entries at and below `path`.
    public func countUnderPath(_ path: String) -> Int {
        guard let id = id(of: path) else { return 0 }
        return subtreeMap([id]).reduce(0) { $0 + Int($1) }
    }

    // MARK: Content

    /// Gets the content index ready for queries (after a crawl, off the query path).
    public func prepareContent() { content.prepare() }

    /// Files (not folders or links) in `scope` that may contain `text`: those whose indexed text has all its
    /// trigrams, and every file whose text isn't indexed (it must be read to know).
    public func contentCandidates(_ text: String, scope: String, cancelled: () -> Bool = { false }) -> [Int] {
        guard !cancelled() else { return [] }
        let indexed = content.candidates(Array(IndexQuery.fold(text).utf8))
        let inScope = scopeMap(scope)
        var result: [Int] = []
        var hits = indexed.map { $0.filter { Int($0) < count } }?.makeIterator()
        var nextHit = hits?.next()
        for i in 0..<count {
            if i & 4095 == 0 && cancelled() { return [] }
            let f = flags[i]
            if f & (Flag.directory | Flag.symlink) != 0 { continue }
            if let m = inScope, m[i] == 0 { continue }
            if f & Flag.content == 0 || indexed == nil {
                result.append(i)
                continue
            }
            while let h = nextHit, Int(h) < i { nextHit = hits?.next() }
            if let h = nextHit, Int(h) == i { result.append(i) }
        }
        return result
    }

    /// nil: everything is in scope; else 1 for the entries below `scope` (the scope's own entry included).
    func scopeMap(_ scope: String?) -> [UInt8]? {
        guard let scope else { return nil }
        // A scope above every root: all of it.
        if roots.allSatisfy({ FilePath.contains(path: storedName(Int($0)), in: scope) }) { return nil }
        guard let id = id(of: scope) else { return [UInt8](repeating: 0, count: count) }
        return subtreeMap([id])
    }

    // MARK: Saving

    public enum Corrupt: Error { case snapshot }
    private static let magic = Array("PORPIDX2".utf8)

    static func put<T>(_ v: T, _ d: inout Data) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }

    static func take<T>(_: T.Type, _ d: Data, _ at: inout Int) throws -> T {
        let n = MemoryLayout<T>.size
        guard at >= d.startIndex, d.endIndex - at >= n else { throw Corrupt.snapshot }
        defer { at += n }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at - d.startIndex, as: T.self) }
    }

    static func take<T>(_: T.Type, _ count: Int, _ d: Data, _ at: inout Int) throws -> [T] {
        let n = MemoryLayout<T>.stride * count
        guard count >= 0, at >= d.startIndex, d.endIndex - at >= n else { throw Corrupt.snapshot }
        defer { at += n }
        return [T](unsafeUninitializedCapacity: count) { buf, done in
            if n > 0 { d.withUnsafeBytes { src in _ = memcpy(buf.baseAddress!, src.baseAddress! + (at - d.startIndex), n) } }
            done = count
        }
    }

    /// "PORPIDX2", the entry count and the folded arena's size, then the columns, the names and the content index.
    public func encoded() -> Data {
        var d = Data(Self.magic)
        Self.put(UInt64(count).littleEndian, &d)
        Self.put(UInt64(folded.count).littleEndian, &d)
        for column in [parents, foldedStarts, nameStarts] { column.withUnsafeBytes { d.append(contentsOf: $0) } }
        sizes.withUnsafeBytes { d.append(contentsOf: $0) }
        mtimes.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(contentsOf: flags)
        d.append(contentsOf: folded)
        Self.put(UInt64(names.count).littleEndian, &d)
        d.append(contentsOf: names)
        content.encode(into: &d)
        return d
    }

    /// Data may be memory mapped. Every offset and parent is checked before the scanner may use it.
    public init(encoded data: Data) throws {
        var at = data.startIndex
        guard data.count >= 24, data.prefix(8).elementsEqual(Self.magic) else { throw Corrupt.snapshot }
        at += 8
        let n = Int(UInt64(littleEndian: try Self.take(UInt64.self, data, &at)))
        let fb = Int(UInt64(littleEndian: try Self.take(UInt64.self, data, &at)))
        guard n >= 0, n < Int(UInt32.max), fb >= 0, fb <= data.count else { throw Corrupt.snapshot }
        parents = try Self.take(UInt32.self, n, data, &at)
        foldedStarts = try Self.take(UInt32.self, n, data, &at)
        nameStarts = try Self.take(UInt32.self, n, data, &at)
        sizes = try Self.take(Int64.self, n, data, &at)
        mtimes = try Self.take(UInt32.self, n, data, &at)
        flags = try Self.take(UInt8.self, n, data, &at)
        folded = try Self.take(UInt8.self, fb, data, &at)
        let nb = Int(UInt64(littleEndian: try Self.take(UInt64.self, data, &at)))
        guard nb >= 0, nb <= data.endIndex - at else { throw Corrupt.snapshot }
        names = try Self.take(UInt8.self, nb, data, &at)
        content = try ContentIndex.decode(data, at: &at, ids: n)
        guard at == data.endIndex else { throw Corrupt.snapshot }
        // What the scanner relies on: parents first, names in order inside the arenas and NUL-terminated.
        guard n == 0 || (foldedStarts[0] == 0 && folded.last == 0), nb == 0 || names.last == 0 else { throw Corrupt.snapshot }
        for i in 0..<n {
            let p = parents[i]
            guard p == Self.noParent || Int(p) < i, i == 0 || foldedStarts[i] > foldedStarts[i - 1], Int(foldedStarts[i]) < fb,
                nameStarts[i] == Self.sameAsFolded || Int(nameStarts[i]) < nb
            else { throw Corrupt.snapshot }
            if p == Self.noParent { roots.append(UInt32(i)) }
        }
        // Roots keep their whole path as written.
        for r in roots where nameStarts[Int(r)] == Self.sameAsFolded { throw Corrupt.snapshot }
    }
}

/// Paths looked up in one snapshot. A class, so a search (which doesn't change the snapshot) can remember them.
final class LookupCache: @unchecked Sendable {
    private var known: [String: Int?] = [:]
    private let lock = NSLock()
    func get(_ path: String) -> Int?? { lock.withLock { known[path] } }
    func set(_ path: String, _ id: Int?) {
        lock.withLock {
            if known.count > 4096 { known = [:] }; known[path] = id
        }
    }
    func clear() { lock.withLock { known = [:] } }
}

extension ContentIndex {
    /// An independent copy (a snapshot that is changed after being copied).
    func copy() -> ContentIndex {
        var d = Data()
        encode(into: &d)
        var at = d.startIndex
        return (try? ContentIndex.decode(d, at: &at, ids: Int.max)) ?? ContentIndex()
    }
}
