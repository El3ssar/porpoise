import Foundation

/// One parsed query and matching policy, independent of which backend discovers candidate paths.
public struct SearchSpec: @unchecked Sendable {
    public let text: String
    public let contents: Bool
    public let query: IndexQuery

    public init(_ text: String, contents: Bool = false, now: Date = Date(), calendar: Calendar = .current) throws {
        self.text = text; self.contents = contents
        query = try contents ? IndexQuery(literal: text) : IndexQuery(text, now: now, calendar: calendar)
    }

    public func nameMatches(_ name: String) -> Bool {
        let folded = IndexQuery.fold(name)
        return query.terms.allSatisfy { folded.contains($0) }
            && (query.regex.map { $0.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil } ?? true)
    }

    public func metadataMatches(path: String, isDirectory: Bool, size: Int64, modified: Date?) -> Bool {
        if let directory = query.directory, directory != isDirectory { return false }
        if let minimum = query.minimumSize, size < minimum { return false }
        if let maximum = query.maximumSize, size > maximum { return false }
        let time = modified?.timeIntervalSince1970 ?? 0
        if let after = query.after, time < after { return false }
        if let before = query.before, time >= before { return false }
        if !query.extensions.isEmpty,
            isDirectory || !query.extensions.contains(IndexQuery.fold((path as NSString).pathExtension))
        {
            return false
        }
        let foldedPath = IndexQuery.fold(path)
        return query.paths.allSatisfy { foldedPath.contains($0) }
    }

    public func contentMatches(_ value: String) -> Bool { IndexQuery.fold(value).contains(query.terms.first ?? "") }

    /// Spotlight can express folded literal terms, but unsupported metadata/regex operators must fall through.
    public var supportsSpotlight: Bool {
        !query.terms.isEmpty && query.paths.isEmpty && query.extensions.isEmpty && query.directory == nil && query.minimumSize == nil
            && query.maximumSize == nil
            && query.after == nil && query.before == nil && query.regex == nil
            && !query.terms.contains { $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]\\")) != nil }
    }
}
