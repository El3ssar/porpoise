import Foundation

public struct CommandCandidate: Sendable, Equatable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var keywords: String
    public var enabled: Bool
    public init(id: String, title: String, subtitle: String = "", keywords: String = "", enabled: Bool = true) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords; self.enabled = enabled
    }
}
public struct CommandMatch: Sendable {
    public let candidate: CommandCandidate
    public let score: Int
}

/// Case/diacritic-insensitive fuzzy subsequence matching, rewarding exact words, prefixes and boundaries.
public enum CommandSearch {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(normalized(query).prefix(256)), haystack = Array(normalized(text).prefix(2048))
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }
        if needle == haystack { return 100_000 }
        if haystack.starts(with: needle) { return 90_000 - haystack.count }
        let text = String(haystack), word = String(needle)
        // Starting a word inside the text ("trash" in "Empty Trash").
        var inWord = false
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: word, range: search) {
            if r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber) {
                return 80_000 - haystack.count
            }
            inWord = true
            search = text.index(after: r.lowerBound)..<text.endIndex
        }
        // The words' initials ("nf" for "New Folder") rank above a match inside a word ("nf" in "Information").
        if isInitials(needle, of: haystack) { return 70_000 - haystack.count }
        if inWord { return 50_000 - haystack.count }
        let impossible = Int.min / 4
        var previous = Array(repeating: impossible, count: haystack.count)
        for (i, character) in needle.enumerated() {
            var current = Array(repeating: impossible, count: haystack.count), best = impossible
            for j in haystack.indices {
                if j > 0, previous[j - 1] > impossible { best = max(best, previous[j - 1] + j - 1) }
                guard character == haystack[j] else { continue }
                let boundary = j == 0 || !haystack[j - 1].isLetter && !haystack[j - 1].isNumber
                let reward = 100 + (boundary ? 45 : 0)
                if i == 0 {
                    current[j] = reward - j
                } else if best > impossible {
                    current[j] = best - j + reward
                    if j > 0, previous[j - 1] > impossible { current[j] = max(current[j], previous[j - 1] + reward + 35) }
                }
            }
            previous = current
        }
        guard let score = previous.max(), score > impossible else { return nil }
        return 10_000 + score - haystack.count
    }
    /// Whether `needle` is, in order, the first letters of some of the words of `haystack`.
    private static func isInitials(_ needle: [Character], of haystack: [Character]) -> Bool {
        var i = 0
        for (j, c) in haystack.enumerated() where i < needle.count {
            let starts = j == 0 || !(haystack[j - 1].isLetter || haystack[j - 1].isNumber)
            if starts && c == needle[i] { i += 1 }
        }
        return i == needle.count && needle.count > 1
    }

    public static func rank(_ query: String, candidates: [CommandCandidate], limit: Int = 200) -> [CommandMatch] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return candidates.compactMap { candidate -> CommandMatch? in
            var total = 0
            for term in terms {
                let title = score(term, in: candidate.title)
                let secondary = score(term, in: candidate.subtitle + " " + candidate.keywords).map { $0 / 2 }
                guard let best = [title, secondary].compactMap({ $0 }).max() else { return nil }
                total += best
            }
            return CommandMatch(candidate: candidate, score: total)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidate.enabled != $1.candidate.enabled { return $0.candidate.enabled }
            let order = $0.candidate.title.localizedStandardCompare($1.candidate.title)
            return order == .orderedSame ? $0.candidate.id < $1.candidate.id : order == .orderedAscending
        }.prefix(max(0, limit)).map { $0 }
    }
}
