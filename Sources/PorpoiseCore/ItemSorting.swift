import Foundation

public enum FilterMode: String, Codable, CaseIterable, Sendable {
    case plainText, glob, regex

    public var title: String {
        switch self {
        case .plainText: return "Plain Text"
        case .glob: return "Glob Pattern"
        case .regex: return "Regular Expression"
        }
    }
}

/// Name filter used by the filter bar (Ctrl+I in Dolphin).
public struct NameFilter: Equatable, Sendable {
    public var text: String
    public var mode: FilterMode
    public var caseSensitive: Bool

    public init(text: String = "", mode: FilterMode = .plainText, caseSensitive: Bool = false) {
        self.text = text
        self.mode = mode
        self.caseSensitive = caseSensitive
    }

    public var isActive: Bool { !text.isEmpty }

    /// nil when the pattern is invalid ("Invalid expression").
    public func matcher() -> ((String) -> Bool)? {
        guard isActive else { return { _ in true } }
        switch mode {
        case .plainText:
            let needle = text
            let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return { $0.range(of: needle, options: opts) != nil }
        case .glob:
            return Self.regexMatcher(Self.globToRegex(text), caseSensitive, extra: [.dotMatchesLineSeparators])
        case .regex:
            return Self.regexMatcher(text, caseSensitive)
        }
    }

    /// Anchored regex for a shell glob: `*`, `?`, `[abc]`, `[!abc]`; everything else literal.
    static func globToRegex(_ glob: String) -> String {
        var pattern = "^"
        var inClass = false
        for ch in glob {
            switch ch {
            case "*" where !inClass: pattern += ".*"
            case "?" where !inClass: pattern += "."
            case "[" where !inClass: inClass = true; pattern += "["
            case "!" where inClass && pattern.hasSuffix("["): pattern += "^"
            case "]" where inClass: inClass = false; pattern += "]"
            case "-" where inClass: pattern += "-"
            default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        // The very end: "$" would also match before a final line break, so "*.txt" took a name ending in ".txt\n".
        return pattern + "\\z"
    }

    private static func regexMatcher(
        _ pattern: String, _ cs: Bool,
        extra: NSRegularExpression.Options = []
    ) -> ((String) -> Bool)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: extra.union(cs ? [] : [.caseInsensitive])) else {
            return nil
        }
        return { s in re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    }
}

public enum SortingChoice: String, Codable, CaseIterable, Sendable {
    case natural, caseInsensitive, caseSensitive

    public var title: String {
        switch self {
        case .natural: return "Natural"
        case .caseInsensitive: return "Alphabetical, case insensitive"
        case .caseSensitive: return "Alphabetical, case sensitive"
        }
    }
}

public enum ItemSorter {
    public static func compareNames(_ a: String, _ b: String, _ choice: SortingChoice) -> ComparisonResult {
        switch choice {
        case .natural: return a.localizedStandardCompare(b)
        case .caseInsensitive: return a.localizedCaseInsensitiveCompare(b)
        case .caseSensitive: return a.compare(b)
        }
    }

    /// Sorts like Dolphin's KFileItemModel: folders first (optional), hidden last (optional), then by role,
    /// with the name as tie breaker. Folders-first ordering is not reversed by a descending sort.
    /// `tags`: Finder tag names per item, needed only when sorting by tags.
    public static func sort(
        _ items: [FileItem], props: ViewProperties, choice: SortingChoice = .natural,
        folderSizes: [URL: Int] = [:], tags: [URL: [String]] = [:]
    ) -> [FileItem] {
        let desc = props.sortOrder == .descending
        return items.sorted { a, b in
            if props.foldersFirst, a.isBrowsableFolder != b.isBrowsableFolder { return a.isBrowsableFolder }
            if props.hiddenLast, a.isHidden != b.isHidden { return !a.isHidden }
            var r = compare(a, b, role: props.sortRole, choice: choice, folderSizes: folderSizes, tags: tags)
            if r == .orderedSame, props.sortRole != .name { r = compareNames(a.name, b.name, choice) }
            if r == .orderedSame { r = a.url.path.compare(b.url.path) }
            return desc ? r == .orderedDescending : r == .orderedAscending
        }
    }

    static func compare(
        _ a: FileItem, _ b: FileItem, role: ItemRole, choice: SortingChoice,
        folderSizes: [URL: Int], tags: [URL: [String]] = [:]
    ) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
        switch role {
        case .name: return compareNames(a.name, b.name, choice)
        case .size:
            if a.isBrowsableFolder && b.isBrowsableFolder {
                return cmp(folderSizes[a.url] ?? 0, folderSizes[b.url] ?? 0)
            }
            return cmp(a.size, b.size)
        case .modificationTime: return cmp(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
        case .creationTime: return cmp(a.creationDate ?? .distantPast, b.creationDate ?? .distantPast)
        case .accessTime: return cmp(a.accessDate ?? .distantPast, b.accessDate ?? .distantPast)
        case .type: return a.typeDescription.localizedStandardCompare(b.typeDescription)
        case .path: return a.url.path.localizedStandardCompare(b.url.path)
        case .extension_: return a.fileExtension.localizedStandardCompare(b.fileExtension)
        case .permissions: return cmp(a.posixPermissions, b.posixPermissions)
        case .owner: return (a.owner ?? "").compare(b.owner ?? "")
        case .group: return (a.group ?? "").compare(b.group ?? "")
        case .linkDestination: return (a.linkDestination ?? "").compare(b.linkDestination ?? "")
        case .tags:
            // Tagged items first (by their tag names, like Finder), untagged ones after them.
            let x = tags[a.url] ?? [], y = tags[b.url] ?? []
            if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
            return x.joined(separator: ", ").localizedStandardCompare(y.joined(separator: ", "))
        }
    }
}

/// Group headers ("Show in Groups" / Group By), following KFileItemModel's group rules.
public enum ItemGrouper {
    /// KFileItemModel's size groups: Small below 5 MiB, Medium below 10 MiB, Big above.
    static let smallSizeLimit: Int64 = 5 * 1024 * 1024
    static let mediumSizeLimit: Int64 = 10 * 1024 * 1024

    public static func groupName(
        _ item: FileItem, role: ItemRole, now: Date = Date(),
        calendar: Calendar = .current, tags: [String] = []
    ) -> String {
        switch role {
        case .name:
            guard let first = item.name.first else { return "" }
            if first.isLetter { return String(first).uppercased() }
            if first.isNumber { return "0 - 9" }
            return "Others"
        case .size:
            if item.isBrowsableFolder { return "Folders" }
            let s = item.size
            if s < smallSizeLimit { return "Small" }
            if s < mediumSizeLimit { return "Medium" }
            return "Big"
        case .modificationTime, .creationTime, .accessTime:
            let date: Date? =
                role == .modificationTime
                ? item.modificationDate
                : (role == .creationTime ? item.creationDate : item.accessDate)
            guard let d = date else { return "Unknown" }
            return dateGroup(d, now: now, calendar: calendar)
        case .type: return item.typeDescription
        case .extension_: return item.fileExtension.isEmpty ? "No extension" : item.fileExtension.lowercased()
        case .owner: return item.owner ?? ""
        case .group: return item.group ?? ""
        case .permissions: return FileFormat.permissions(item.posixPermissions, isDirectory: item.isDirectory)
        case .path: return item.url.deletingLastPathComponent().path
        case .linkDestination: return item.linkDestination ?? ""
        case .tags: return tags.first ?? "No Tags"
        }
    }

    /// Splits sorted items into titled groups. Items keep their order inside a group. Folders-first and hidden-last
    /// keep their sections: a folder group never takes files in (Dolphin starts a new group there). Grouped by the
    /// sort role, groups follow the sort order; grouped by another role, groups with the same title are merged and
    /// ordered by that role (dates newest first).
    public static func groups(
        _ sorted: [FileItem], role: ItemRole, props: ViewProperties, choice: SortingChoice = .natural,
        folderSizes: [URL: Int] = [:], tags: [URL: [String]] = [:], now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(title: String, items: [FileItem])] {
        struct Key: Hashable { let section: Int; let title: String }
        func section(_ it: FileItem) -> Int {
            (props.foldersFirst && !it.isBrowsableFolder ? 2 : 0) + (props.hiddenLast && it.isHidden ? 1 : 0)
        }
        var order: [Key] = []
        var buckets: [Key: [FileItem]] = [:]
        for it in sorted {
            let k = Key(section: section(it), title: groupName(it, role: role, now: now, calendar: calendar, tags: tags[it.url] ?? []))
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(it)
        }
        if role != props.sortRole {
            let newestFirst = role == .modificationTime || role == .creationTime || role == .accessTime
            // Stable: sections keep their order, and groups the role can't tell apart keep theirs.
            order = order.enumerated().sorted { x, y in
                if x.element.section != y.element.section { return x.element.section < y.element.section }
                let a = buckets[x.element]![0], b = buckets[y.element]![0]
                var r = ItemSorter.compare(a, b, role: role, choice: choice, folderSizes: folderSizes, tags: tags)
                if newestFirst { r = r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : r) }
                return r == .orderedSame ? x.offset < y.offset : r == .orderedAscending
            }.map(\.element)
        }
        return order.map { (title: $0.title, items: buckets[$0]!) }
    }

    /// Today / Yesterday / weekday this week / Last Week / month names / years — like Dolphin.
    public static func dateGroup(_ d: Date, now: Date, calendar: Calendar) -> String {
        let startToday = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: d)
        let days = calendar.dateComponents([.day], from: startDay, to: startToday).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return FileFormat.formatter("EEEE", calendar: calendar).string(from: d) }
        if days < 14 { return "One Week Ago" }
        if days < 21 { return "Two Weeks Ago" }
        if days < 28 { return "Three Weeks Ago" }
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        return FileFormat.formatter(sameYear ? "MMMM" : "MMMM yyyy", calendar: calendar).string(from: d)
    }
}
