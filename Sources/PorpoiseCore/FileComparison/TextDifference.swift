import Foundation

/// Half-open ranges in the original line arrays. Applying every right range to the left reconstructs the right file.
public struct TextChange: Equatable, Sendable {
    public let left: Range<Int>
    public let right: Range<Int>
    public init(left: Range<Int>, right: Range<Int>) { self.left = left; self.right = right }
}

public struct TextDifference: Sendable {
    /// Lines retain their terminators, including CRLF and the absence of a final newline.
    public let left: [String]
    public let right: [String]
    public let changes: [TextChange]
    public let ignoreWhitespace: Bool

    public init(left: String, right: String, ignoreWhitespace: Bool = false) {
        self.left = Self.lines(left); self.right = Self.lines(right); self.ignoreWhitespace = ignoreWhitespace
        let a = ignoreWhitespace ? self.left.map(Self.normalized) : self.left
        let b = ignoreWhitespace ? self.right.map(Self.normalized) : self.right
        var matches: [(Int, Int)] = []
        Self.match(a, b, 0..<a.count, 0..<b.count, into: &matches, depth: 0)
        matches.sort { $0.0 < $1.0 }
        var changes: [TextChange] = [], i = 0, j = 0
        for (x, y) in matches {
            if x > i || y > j { changes.append(TextChange(left: i..<x, right: j..<y)) }
            i = x + 1; j = y + 1
        }
        if i < a.count || j < b.count { changes.append(TextChange(left: i..<a.count, right: j..<b.count)) }
        self.changes = changes
    }

    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // String's Character iteration treats CRLF as one grapheme. Splitting on LF alone would miss it.
        var result: [String] = [], start = text.startIndex
        for i in text.indices where text[i] == "\n" || text[i] == "\r\n" || text[i] == "\r" {
            let end = text.index(after: i); result.append(String(text[start..<end])); start = end
        }
        if start != text.endIndex { result.append(String(text[start...])) }
        return result
    }
    private static func normalized(_ line: String) -> String { line.filter { !$0.isWhitespace } }

    /// Patience anchors partition the problem; bounded Myers handles duplicate-line gaps. The bound avoids
    /// quadratic trace memory on unrelated large files: those gaps remain one exact replacement block.
    private static func match(_ a: [String], _ b: [String], _ ar: Range<Int>, _ br: Range<Int>, into result: inout [(Int, Int)], depth: Int) {
        var lo = ar.lowerBound, ro = br.lowerBound, hi = ar.upperBound, rh = br.upperBound
        while lo < hi && ro < rh && a[lo] == b[ro] { result.append((lo, ro)); lo += 1; ro += 1 }
        var suffix: [(Int, Int)] = []
        while lo < hi && ro < rh && a[hi - 1] == b[rh - 1] { hi -= 1; rh -= 1; suffix.append((hi, rh)) }
        defer { result.append(contentsOf: suffix.reversed()) }
        guard lo < hi, ro < rh else { return }
        if depth < 64 {
            var ac: [String: Int] = [:], bc: [String: Int] = [:]
            for i in lo..<hi { ac[a[i]] = ac[a[i]] == nil ? i : -1 }
            for j in ro..<rh { bc[b[j]] = bc[b[j]] == nil ? j : -1 }
            let pairs = (lo..<hi).compactMap { i -> (Int, Int)? in
                guard ac[a[i]] == i, let j = bc[a[i]], j >= 0 else { return nil }; return (i, j)
            }
            var tails: [Int] = [], previous = Array(repeating: -1, count: pairs.count)
            for p in pairs.indices {
                var l = 0, r = tails.count
                while l < r { let m = (l + r) / 2; if pairs[tails[m]].1 < pairs[p].1 { l = m + 1 } else { r = m } }
                if l > 0 { previous[p] = tails[l - 1] }
                if l == tails.count { tails.append(p) } else { tails[l] = p }
            }
            if let last = tails.last {
                var anchors: [(Int, Int)] = [], p = last
                while p >= 0 { anchors.append(pairs[p]); p = previous[p] }
                var x = lo, y = ro
                for (i, j) in anchors.reversed() {
                    match(a, b, x..<i, y..<j, into: &result, depth: depth + 1); result.append((i, j)); x = i + 1; y = j + 1
                }
                match(a, b, x..<hi, y..<rh, into: &result, depth: depth + 1); return
            }
        }
        result.append(contentsOf: myers(a, b, lo..<hi, ro..<rh))
    }

    private static func myers(_ a: [String], _ b: [String], _ ar: Range<Int>, _ br: Range<Int>) -> [(Int, Int)] {
        let n = ar.count, m = br.count, limit = min(n + m, 512)
        var v = [1: 0], trace: [[Int: Int]] = []
        for d in 0...limit {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1, default: -1] < v[k + 1, default: -1]) {
                    x = v[k + 1, default: 0]
                } else {
                    x = v[k - 1, default: 0] + 1
                }
                var y = x - k
                while x < n && y < m && x >= 0 && y >= 0 && a[ar.lowerBound + x] == b[br.lowerBound + y] { x += 1; y += 1 }
                v[k] = x
                if x >= n && y >= m {
                    var x = n, y = m, matches: [(Int, Int)] = []
                    for step in stride(from: d, through: 0, by: -1) {
                        let before = trace[step], k = x - y
                        let pk = k == -step || (k != step && before[k - 1, default: -1] < before[k + 1, default: -1]) ? k + 1 : k - 1
                        let px = before[pk, default: 0], py = px - pk
                        while x > px && y > py { x -= 1; y -= 1; matches.append((ar.lowerBound + x, br.lowerBound + y)) }
                        x = px; y = py
                    }
                    return matches.reversed()
                }
            }
        }
        return []
    }

    public func copying(_ change: Int, toRight: Bool) -> String? {
        guard changes.indices.contains(change) else { return nil }
        let c = changes[change]
        var lines = toRight ? right : left
        lines.replaceSubrange(toRight ? c.right : c.left, with: (toRight ? left[c.left] : right[c.right]))
        return lines.joined()
    }
}

/// Word boundaries retain punctuation and spaces; ranges use UTF-16 for AppKit text drawing.
public enum WordDifference {
    public static func ranges(_ left: String, _ right: String) -> (left: [NSRange], right: [NSRange]) {
        func tokens(_ text: String) -> [String] {
            var result: [String] = [], word = "", kind: Int?
            for c in text {
                let next = c.isLetter || c.isNumber || c == "_" ? 0 : (c.isWhitespace ? 1 : 2)
                if kind != next || next == 2 { if !word.isEmpty { result.append(word) }; word = "" }
                word.append(c); kind = next
            }
            if !word.isEmpty { result.append(word) }; return result
        }
        let a = tokens(left), b = tokens(right)
        // Word rows are deliberately bounded; a huge single line gets a single span without a costly diff.
        guard a.count + b.count < 4096 else {
            return ([NSRange(location: 0, length: left.utf16.count)], [NSRange(location: 0, length: right.utf16.count)])
        }
        let d = TextDifference(left: a.map { $0 + "\n" }.joined(), right: b.map { $0 + "\n" }.joined())
        let ac = a.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
        let bc = b.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
        return (
            d.changes.map { NSRange(location: ac[$0.left.lowerBound], length: ac[$0.left.upperBound] - ac[$0.left.lowerBound]) },
            d.changes.map { NSRange(location: bc[$0.right.lowerBound], length: bc[$0.right.upperBound] - bc[$0.right.lowerBound]) }
        )
    }
}
