import Foundation

/// Quick Select: which items of a folder a name pattern, an extension or a tag picks, and how that changes the
/// selection (Total Commander's Select Group, Finder has no such thing).
public struct QuickSelect: Codable, Equatable, Sendable {
    public enum Criterion: String, Codable, CaseIterable, Sendable {
        case name, fileExtension, tag

        public var title: String {
            switch self {
            case .name: return "Name"
            case .fileExtension: return "Extension"
            case .tag: return "Tag"
            }
        }

        public var placeholder: String {
            switch self {
            case .name: return "*.jpg; report*"
            case .fileExtension: return "jpg, png"
            case .tag: return "Red, Work"
            }
        }
    }

    /// What the matching items do to the selection.
    public enum Action: String, Codable, CaseIterable, Sendable {
        /// The matching items become the selection.
        case select
        /// They join it.
        case add
        /// They leave it.
        case remove
    }

    /// One item as Quick Select sees it.
    public struct Candidate: Sendable {
        public var id: URL
        public var name: String
        public var isFolder: Bool
        public var tags: [String]

        public init(id: URL, name: String, isFolder: Bool, tags: [String] = []) {
            self.id = id
            self.name = name
            self.isFolder = isFolder
            self.tags = tags
        }
    }

    public var criterion: Criterion
    public var text: String
    public var caseSensitive: Bool

    public init(_ criterion: Criterion = .name, _ text: String = "", caseSensitive: Bool = false) {
        self.criterion = criterion
        self.text = text
        self.caseSensitive = caseSensitive
    }

    /// The text's terms: separated by `;` or `,` (and, for extensions and tags, spaces too), trimmed, none empty.
    public var terms: [String] {
        var separators = CharacterSet(charactersIn: ";,")
        if criterion == .fileExtension { separators.formUnion(.whitespaces) }
        return text.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Something to match: at least one term (and, for a name pattern, every term a valid one).
    public var isValid: Bool { matcher() != nil }

    /// Whether an item matches; nil when there's nothing to match by or a pattern is invalid.
    ///
    /// - Name: each term is a glob (`*`, `?`, `[a-z]`) matched against the whole name; a term without wildcards
    ///   matches names that contain it.
    /// - Extension: each term with or without its dot, against the last extension of a file's name ("tar.gz" against
    ///   the last two). Folders never match.
    /// - Tag: items carrying any of the tags.
    public func matcher() -> ((Candidate) -> Bool)? {
        let terms = self.terms
        guard !terms.isEmpty else { return nil }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        switch criterion {
        case .name:
            var matchers: [(String) -> Bool] = []
            for term in terms {
                let glob = term.contains(where: { "*?[".contains($0) })
                guard let m = NameFilter(text: term, mode: glob ? .glob : .plainText, caseSensitive: caseSensitive).matcher() else {
                    return nil
                }
                matchers.append(m)
            }
            return { c in matchers.contains { $0(c.name) } }
        case .fileExtension:
            let wanted = terms.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
            guard !wanted.isEmpty else { return nil }
            return { c in
                guard !c.isFolder else { return false }
                return wanted.contains { ext in
                    let suffix = "." + ext
                    guard c.name.count > suffix.count else { return false }
                    return c.name.range(of: suffix, options: options.union(.anchored).union(.backwards)) != nil
                }
            }
        case .tag:
            return { c in terms.contains { t in c.tags.contains { $0.compare(t, options: options) == .orderedSame } } }
        }
    }

    /// The selection after `action` with the items that match among `candidates`; nil when nothing can match.
    public func apply(_ action: Action, to selection: Set<URL>, in candidates: [Candidate]) -> Set<URL>? {
        guard let matches = matcher() else { return nil }
        let picked = Set(candidates.lazy.filter(matches).map(\.id))
        switch action {
        case .select: return picked
        case .add: return selection.union(picked)
        case .remove: return selection.subtracting(picked)
        }
    }

    /// Extensions of the files among `candidates`, the most common first (for the field's suggestions).
    public static func commonExtensions(in candidates: [Candidate], limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        for c in candidates where !c.isFolder {
            let ext = (c.name as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 12 { counts[ext, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// Tags among `candidates`, the most common first.
    public static func commonTags(in candidates: [Candidate], limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        for c in candidates { for t in Set(c.tags) { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }
}
