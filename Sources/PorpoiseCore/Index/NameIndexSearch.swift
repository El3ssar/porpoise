import Darwin
import Foundation

/// The columns as raw pointers for the length of one search (the snapshot doesn't change meanwhile).
struct Columns: @unchecked Sendable {
    let count: Int
    let parents: UnsafePointer<UInt32>
    let starts: UnsafePointer<UInt32>
    let sizes: UnsafePointer<Int64>
    let mtimes: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    let arena: UnsafePointer<UInt8>
    let arenaCount: Int

    /// Folded name of entry `i`: start and length (without its NUL).
    @inline(__always) func name(_ i: Int) -> (UnsafePointer<UInt8>, Int) {
        let s = Int(starts[i])
        let e = i + 1 < count ? Int(starts[i + 1]) - 1 : arenaCount - 1
        return (arena + s, e - s)
    }
}

/// One condition, ready to be checked against an entry without allocating.
enum Check {
    case directory(Bool)
    case size(Int64, Int64)
    case modified(Double, Double)
    case name(UnsafeMutableBufferPointer<UInt8>)
    case ext([UnsafeMutableBufferPointer<UInt8>])
    /// Answers worked out for every entry beforehand (paths, scope, exclusions, regexes).
    case map(UnsafeMutablePointer<UInt8>, want: UInt8)
}

extension NameIndex {
    func withColumns<T>(_ body: (Columns) -> T) -> T {
        parents.withUnsafeBufferPointer { p in
            foldedStarts.withUnsafeBufferPointer { st in
                sizes.withUnsafeBufferPointer { sz in
                    mtimes.withUnsafeBufferPointer { mt in
                        flags.withUnsafeBufferPointer { fl in
                            folded.withUnsafeBufferPointer { a in
                                // Empty arrays may have no base address; nothing is read from them then.
                                let d32 = UnsafePointer<UInt32>(bitPattern: 0x10)!, d8 = UnsafePointer<UInt8>(bitPattern: 0x10)!
                                return body(
                                    Columns(
                                        count: p.count, parents: p.baseAddress ?? d32, starts: st.baseAddress ?? d32,
                                        sizes: sz.baseAddress ?? UnsafePointer(bitPattern: 0x10)!, mtimes: mt.baseAddress ?? d32,
                                        flags: fl.baseAddress ?? d8, arena: a.baseAddress ?? d8, arenaCount: a.count))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Returns ids in stable crawl order: the first `limit` entries matching `query`, in `scope`, outside the
    /// `excluding` subtrees. Runs on all cores; `cancelled` is asked as each part starts and every 4096 entries.
    public func search(
        _ query: IndexQuery, scope: String? = nil, limit: Int = 5000, excluding: [String] = [], cancelled: () -> Bool = { false }
    ) -> [Int] {
        guard limit > 0, count > 0, !cancelled() else { return [] }
        var scratch = SearchScratch()
        defer { scratch.free() }
        let n = count
        // Where to look: the scope minus the excluded subtrees.
        var region: [UInt8]?
        if let s = scopeMap(scope) {
            region = s
            if !s.contains(1) { return [] }
        }
        let excludedIds = excluding.compactMap { id(of: $0) }
        if !excludedIds.isEmpty {
            let x = subtreeMap(excludedIds)
            if region == nil { region = [UInt8](repeating: 1, count: n) }
            for i in 0..<n where x[i] == 1 { region![i] = 0 }
        }
        return withColumns { cols in
            var checks: [Check] = []
            if let region { checks.append(.map(scratch.copyMap(region), want: 1)) }
            if let d = query.directory { checks.append(.directory(d)) }
            if query.minimumSize != nil || query.maximumSize != nil {
                checks.append(.size(query.minimumSize ?? .min, query.maximumSize ?? .max))
            }
            if query.after != nil || query.before != nil {
                checks.append(.modified(query.after ?? -.infinity, query.before ?? .infinity))
            }
            // The longest word drives the scan; the others are checked on its hits.
            let words = query.terms.map { Array($0.utf8) }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            let needle = words.first
            for w in words.dropFirst() { checks.append(.name(scratch.copy(w))) }
            if !query.extensions.isEmpty { checks.append(.ext(query.extensions.map { scratch.copy(Array($0.utf8)) })) }
            for p in query.paths where !p.isEmpty { checks.append(.map(scratch.pathMap(cols, Array(p.utf8), roots: rootPaths()), want: 1)) }
            if let re = query.regex { checks.append(.map(scratch.regexMap(cols, re, cancelled: cancelled), want: 1)) }
            if cancelled() { return [] }

            let chunks = max(1, min(n / 8192, ProcessInfo.processInfo.activeProcessorCount * 4))
            var parts = [[Int]](repeating: [], count: chunks)
            let checksCopy = checks
            parts.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    if cancelled() { return }
                    let lo = n * c / chunks, hi = n * (c + 1) / chunks
                    var found: [Int] = []
                    // Each part keeps at most `limit`: only the first `limit` of all count.
                    if let needle {
                        Self.scan(needle, cols: cols, entries: lo..<hi) { id in
                            guard found.count < limit else { return false }
                            if Self.accept(id, cols: cols, checks: checksCopy) { found.append(id) }
                            return true
                        }
                    } else {
                        var i = lo
                        while i < hi && found.count < limit {
                            if (i - lo) & 4095 == 4095 && cancelled() { return }
                            if Self.accept(i, cols: cols, checks: checksCopy) { found.append(i) }
                            i += 1
                        }
                    }
                    base[c] = found
                }
            }
            if cancelled() { return [] }
            var result: [Int] = []
            for p in parts {
                result.append(contentsOf: p.prefix(limit - result.count))
                if result.count == limit { break }
            }
            return result
        }
    }

    /// The folded whole path of each root, by entry.
    func rootPaths() -> [Int: [UInt8]] {
        Dictionary(uniqueKeysWithValues: roots.map { (Int($0), Array(IndexQuery.fold(storedName(Int($0))).utf8)) })
    }

    @inline(__always)
    static func accept(_ id: Int, cols: Columns, checks: [Check]) -> Bool {
        for check in checks where !matches(check, id, cols: cols) { return false }
        return true
    }

    @inline(__always)
    static func matches(_ check: Check, _ i: Int, cols: Columns) -> Bool {
        switch check {
        case .directory(let d):
            return (cols.flags[i] & Flag.directory != 0) == d
        case .size(let lo, let hi):
            let s = cols.sizes[i]
            return s >= lo && s <= hi
        case .modified(let lo, let hi):
            let m = Double(cols.mtimes[i])
            return m >= lo && m < hi
        case .map(let m, let want):
            return m[i] == want
        case .name(let needle):
            let (p, n) = cols.name(i)
            return n >= needle.count && memmem(p, n, needle.baseAddress!, needle.count) != nil
        case .ext(let exts):
            // As NSString.pathExtension: after the last dot, unless the dot starts the name; folders have none.
            if cols.flags[i] & Flag.directory != 0 { return false }
            let (p, n) = cols.name(i)
            var dot = n - 1
            while dot > 0 && p[dot] != UInt8(ascii: ".") { dot -= 1 }
            let start = dot > 0 ? dot + 1 : n
            let len = n - start
            for e in exts where e.count == len && (len == 0 || memcmp(p + start, e.baseAddress!, len) == 0) { return true }
            return false
        }
    }

    /// Calls `hit` once for each entry in `entries` whose folded name contains `needle`, until it returns false.
    static func scan(_ needle: [UInt8], cols: Columns, entries: Range<Int>, hit: (Int) -> Bool) {
        guard !entries.isEmpty, !needle.isEmpty else { return }
        needle.withUnsafeBufferPointer { nd in
            let base = cols.arena, starts = cols.starts
            let end = entries.upperBound < cols.count ? Int(starts[entries.upperBound]) : cols.arenaCount
            var at = Int(starts[entries.lowerBound])
            var entry = entries.lowerBound
            let last = entries.upperBound - 1
            while at < end {
                guard let p = memmem(base + at, end - at, nd.baseAddress!, nd.count) else { break }
                let pos = UnsafePointer<UInt8>(p.assumingMemoryBound(to: UInt8.self)) - base
                // The entry holding `pos`: the last start at or before it. Usually close by: gallop, then bisect.
                var lo = entry, step = 1
                while lo + step <= last && Int(starts[lo + step]) <= pos {
                    lo += step
                    step <<= 1
                }
                var hi = min(last, lo + step)
                while lo < hi {
                    let mid = (lo + hi + 1) >> 1
                    if Int(starts[mid]) <= pos { lo = mid } else { hi = mid - 1 }
                }
                if !hit(lo) { return }
                guard lo < last else { break }
                entry = lo + 1
                at = Int(starts[entry])
            }
        }
    }
}

/// Memory one search needs (needles, per-entry answers), freed when it ends.
struct SearchScratch {
    private var bytes: [UnsafeMutableBufferPointer<UInt8>] = []
    private var maps: [UnsafeMutablePointer<UInt8>] = []

    mutating func free() {
        bytes.forEach { $0.deallocate() }
        maps.forEach { $0.deallocate() }
    }

    mutating func copy(_ b: [UInt8]) -> UnsafeMutableBufferPointer<UInt8> {
        let p = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, b.count))
        _ = p.initialize(from: b)
        bytes.append(p)
        return UnsafeMutableBufferPointer(rebasing: p[0..<b.count])
    }

    mutating func copyMap(_ m: [UInt8]) -> UnsafeMutablePointer<UInt8> {
        let p = map(m.count)
        m.withUnsafeBufferPointer { _ = memcpy(p, $0.baseAddress!, m.count) }
        return p
    }

    mutating func map(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        let m = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, n))
        m.initialize(repeating: 0, count: max(1, n))
        maps.append(m)
        return m
    }

    private static func chunks(_ n: Int) -> Int { max(1, min(n / 8192, ProcessInfo.processInfo.activeProcessorCount * 4)) }

    /// 1 for entries whose folded whole path contains `needle`. A match ends in some entry's name, which then holds
    /// the needle's last part (after its last /): those entries are found by scanning the arena and checked against
    /// the end of their path; their descendants match too. Roots are checked by their whole path.
    mutating func pathMap(_ cols: Columns, _ needle: [UInt8], roots: [Int: [UInt8]]) -> UnsafeMutablePointer<UInt8> {
        let m = map(cols.count)
        let hasSlash = needle.contains(UInt8(ascii: "/"))
        let lastPart = Array(needle.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).last ?? [])
        let check = { (i: Int) -> Bool in
            if roots[i] != nil { return false }  // below, by whole path
            return !hasSlash || Self.pathEndContains(cols, i, needle, roots: roots)
        }
        if lastPart.isEmpty {
            for i in 0..<cols.count where check(i) { m[i] = 1 }
        } else {
            let lock = NSLock()
            var hits: [Int] = []
            let n = cols.count, k = Self.chunks(n)
            DispatchQueue.concurrentPerform(iterations: k) { c in
                var local: [Int] = []
                NameIndex.scan(lastPart, cols: cols, entries: (n * c / k)..<(n * (c + 1) / k)) { i in
                    if check(i) { local.append(i) }
                    return true
                }
                lock.withLock { hits.append(contentsOf: local) }
            }
            for i in hits { m[i] = 1 }
        }
        for (r, path) in roots where path.count >= needle.count {
            if path.withUnsafeBufferPointer({ p in
                needle.withUnsafeBufferPointer { memmem(p.baseAddress!, p.count, $0.baseAddress!, $0.count) != nil }
            }) {
                m[r] = 1
            }
        }
        for i in 0..<cols.count where m[i] == 0 {
            let p = cols.parents[i]
            if p != NameIndex.noParent && m[Int(p)] == 1 { m[i] = 1 }
        }
        return m
    }

    /// Whether the needle occurs in the folded path of `i` (the parent's path checked as far back as the needle can
    /// reach).
    static func pathEndContains(_ cols: Columns, _ i: Int, _ needle: [UInt8], roots: [Int: [UInt8]]) -> Bool {
        let (op, on) = cols.name(i)
        var tail = Array(UnsafeBufferPointer(start: op, count: on))
        var cur = i
        while tail.count - on < needle.count, cols.parents[cur] != NameIndex.noParent {
            cur = Int(cols.parents[cur])
            let part: [UInt8]
            if let r = roots[cur] {
                part = r
            } else {
                let (p, n) = cols.name(cur)
                part = Array(UnsafeBufferPointer(start: p, count: n))
            }
            tail = part + (part.last == UInt8(ascii: "/") ? [] : [UInt8(ascii: "/")]) + tail
        }
        return tail.count >= needle.count
            && tail.withUnsafeBufferPointer { t in
                needle.withUnsafeBufferPointer { memmem(t.baseAddress!, t.count, $0.baseAddress!, $0.count) != nil }
            }
    }

    /// 1 for entries whose folded name matches `re`: POSIX regexec on the name's bytes where the pattern allows (no
    /// String per name), else NSRegularExpression.
    mutating func regexMap(_ cols: Columns, _ re: NSRegularExpression, cancelled: () -> Bool) -> UnsafeMutablePointer<UInt8> {
        let m = map(cols.count)
        let n = cols.count, k = Self.chunks(n)
        if let ere = Self.posixPattern(re.pattern) {
            var compiled = regex_t()
            if regcomp(&compiled, ere, REG_EXTENDED | REG_ICASE | REG_NOSUB) == 0 {
                defer { regfree(&compiled) }
                withUnsafePointer(to: &compiled) { rp in
                    DispatchQueue.concurrentPerform(iterations: k) { c in
                        if cancelled() { return }
                        for i in (n * c / k)..<(n * (c + 1) / k) {
                            let p = cols.arena + Int(cols.starts[i])
                            if p.withMemoryRebound(to: CChar.self, capacity: 1, { regexec(rp, $0, 0, nil, 0) }) == 0 { m[i] = 1 }
                        }
                    }
                }
                return m
            }
        }
        DispatchQueue.concurrentPerform(iterations: k) { c in
            for i in (n * c / k)..<(n * (c + 1) / k) {
                if (i & 1023) == 0 && cancelled() { return }
                let (p, len) = cols.name(i)
                let s = String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
                if re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil { m[i] = 1 }
            }
        }
        return m
    }

    /// `p` (ICU syntax) as a POSIX extended regex with the same meaning, or nil when it uses what POSIX lacks
    /// (lookaround, lazy or possessive quantifiers, \b, escapes inside brackets, Unicode classes).
    static func posixPattern(_ p: String) -> String? {
        var out = ""
        let it = Array(p)
        var i = 0
        var inBracket = false
        while i < it.count {
            let ch = it[i]
            if inBracket {
                if ch == "\\" { return nil }
                if ch == "]" { inBracket = false }
                out.append(ch)
                i += 1
                continue
            }
            switch ch {
            case "[":
                inBracket = true
                out.append(ch)
                // A ] right after [ or [^ is a literal.
                if i + 1 < it.count, it[i + 1] == "^" {
                    out.append("^")
                    i += 1
                }
                if i + 1 < it.count, it[i + 1] == "]" {
                    out.append("]")
                    i += 1
                }
            case "(":
                if i + 1 < it.count, it[i + 1] == "?" { return nil }
                out.append(ch)
            case "*", "+", "?", "}":
                if i + 1 < it.count, it[i + 1] == "?" || it[i + 1] == "+" { return nil }
                out.append(ch)
            case "\\":
                guard i + 1 < it.count else { return nil }
                let e = it[i + 1]
                i += 1
                switch e {
                case "d": out += "[0-9]"
                case "D": out += "[^0-9]"
                case "w": out += "[[:alnum:]_]"
                case "W": out += "[^[:alnum:]_]"
                case "s": out += "[[:space:]]"
                case "S": out += "[^[:space:]]"
                case ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$", "\\": out += "\\" + String(e)
                case "/", "-", " ", "_": out.append(e)
                default: return nil
                }
            default:
                // Folded names: the pattern is matched without case, so only its other characters matter.
                out.append(ch)
            }
            i += 1
        }
        return inBracket ? nil : out
    }
}
