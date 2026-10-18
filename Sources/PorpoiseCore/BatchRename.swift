import Foundation

public enum RenameCase: String, Codable, CaseIterable, Sendable { case unchanged, lower, upper, title, sentence }
public enum RenameExtension: Codable, Equatable, Sendable { case keep, lowercase, change(String), includeInRules }

/// Rules operate in order on the stem; extension handling happens once, after the pipeline.
/// Positions count user-perceived characters from zero; -1 means the end.
public enum BatchRenameRule: Codable, Equatable, Sendable {
    case template(String)
    case replace(find: String, with: String, regex: Bool, caseSensitive: Bool)
    case number(start: Int, step: Int, padding: Int, position: Int)
    case changeCase(RenameCase)
    case insert(text: String, position: Int)
    case remove(position: Int, count: Int)
}

public struct BatchRenamePreset: Codable, Equatable, Sendable {
    public var name: String
    public var rules: [BatchRenameRule]
    public var extensionMode: RenameExtension
    public init(name: String, rules: [BatchRenameRule] = [], extensionMode: RenameExtension = .keep) {
        self.name = name; self.rules = rules; self.extensionMode = extensionMode
    }
}

public struct BatchRenameEntry: Sendable {
    public let url: URL
    public var isDirectory: Bool
    public var created: Date?
    public var modified: Date?
    public var exifDate: Date?
    public var metadata: [String: String]
    public init(
        url: URL, isDirectory: Bool = false, created: Date? = nil, modified: Date? = nil, exifDate: Date? = nil, metadata: [String: String] = [:]
    ) {
        self.url = url; self.isDirectory = isDirectory; self.created = created; self.modified = modified; self.exifDate = exifDate;
        self.metadata = metadata
    }
}

public struct RenameMove: Codable, Equatable, Sendable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public struct BatchRenameRow: Sendable {
    public let source: URL
    public var proposedName: String
    public var problem: String?
    public var changes: Bool { !source.lastPathComponent.utf8.elementsEqual(proposedName.utf8) }
    public var target: URL { source.deletingLastPathComponent().appendingPathComponent(proposedName) }
}

public struct BatchRenamePlan: Sendable {
    public var rows: [BatchRenameRow]
    /// Two phases: stage every changing source, then place every staged item. Handles swaps and cycles.
    public let steps: [RenameMove]
    public var canApply: Bool { rows.contains(where: \.changes) && rows.allSatisfy { $0.problem == nil } }
    public var changes: [BatchRenameRow] { rows.filter(\.changes) }
}

public enum BatchRenameError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum BatchRename {
    public static func names(_ entries: [BatchRenameEntry], preset: BatchRenamePreset, timeZone: TimeZone = .current) -> [Result<String, Error>] {
        entries.enumerated().map { index, entry in Result { try name(entry, index: index, preset: preset, timeZone: timeZone) } }
    }

    public static func name(_ entry: BatchRenameEntry, index: Int, preset: BatchRenamePreset, timeZone: TimeZone = .current) throws -> String {
        let original = entry.url.lastPathComponent
        let ext = entry.isDirectory ? "" : (original as NSString).pathExtension
        // NSString's own split: counting Characters would be off when a combining mark follows the dot.
        let stem = ext.isEmpty ? original : (original as NSString).deletingPathExtension
        var name = preset.extensionMode == .includeInRules ? original : stem
        for rule in preset.rules {
            switch rule {
            case .template(let template): name = try tokens(template, entry: entry, stem: stem, ext: ext, timeZone: timeZone)
            case .replace(let find, let replacement, let regex, let caseSensitive):
                guard !find.isEmpty else { continue }
                let replacement = try tokens(replacement, entry: entry, stem: stem, ext: ext, timeZone: timeZone, regexReplacement: regex)
                if regex {
                    let expression = try Self.expression(find, options: caseSensitive ? [] : [.caseInsensitive])
                    name = expression.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: replacement)
                } else {
                    name = name.replacingOccurrences(of: find, with: replacement, options: caseSensitive ? [] : [.caseInsensitive])
                }
            case .number(let start, let step, let padding, let position):
                guard (0...32).contains(padding), index >= 0 else { throw BatchRenameError.invalid("Number padding must be between 0 and 32.") }
                let product = step.multipliedReportingOverflow(by: index)
                let sum = start.addingReportingOverflow(product.partialValue)
                guard !product.overflow, !sum.overflow else { throw BatchRenameError.invalid("The numbering sequence is too large.") }
                let number = sum.partialValue
                let digits = String(number.magnitude)
                let padded = (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, padding - digits.count)) + digits
                name = try insert(padded, into: name, at: position)
            case .changeCase(let change):
                switch change {
                case .unchanged: break
                case .lower: name = name.lowercased()
                case .upper: name = name.uppercased()
                case .title: name = name.capitalized
                case .sentence: name = name.prefix(1).uppercased() + name.dropFirst().lowercased()
                }
            case .insert(let text, let position):
                name = try insert(tokens(text, entry: entry, stem: stem, ext: ext, timeZone: timeZone), into: name, at: position)
            case .remove(let position, let count):
                guard position >= 0, count >= 0 else { throw BatchRenameError.invalid("Remove position and count must be nonnegative.") }
                let start = name.index(name.startIndex, offsetBy: min(position, name.count))
                let end = name.index(start, offsetBy: min(count, name.distance(from: start, to: name.endIndex)))
                name.removeSubrange(start..<end)
            }
        }
        guard !entry.isDirectory else { return name }
        switch preset.extensionMode {
        case .keep: return name + (ext.isEmpty ? "" : "." + ext)
        case .lowercase: return name + (ext.isEmpty ? "" : "." + ext.lowercased())
        case .change(let typed):
            // "jpg" or ".jpg", as people type it.
            let new = typed.drop { $0 == "." }
            return name + (new.isEmpty ? "" : "." + new)
        case .includeInRules: return name
        }
    }

    private static func insert(_ text: String, into name: String, at position: Int) throws -> String {
        guard position >= -1 else { throw BatchRenameError.invalid("Insert position must be -1 (end) or nonnegative.") }
        let offset = position == -1 ? name.count : min(position, name.count)
        let i = name.index(name.startIndex, offsetBy: offset)
        return String(name[..<i]) + text + String(name[i...])
    }

    /// Compiled once per pattern, not once per file: a preview renames the whole selection on each keystroke.
    /// Bounded, since each keystroke of a pattern being typed is a pattern of its own.
    nonisolated(unsafe) private static var expressions: [String: NSRegularExpression] = [:]
    private static let expressionsLock = NSLock()
    private static func expression(_ pattern: String, options: NSRegularExpression.Options) throws -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        if let e = expressionsLock.withLock({ expressions[key] }) { return e }
        let e = try NSRegularExpression(pattern: pattern, options: options)
        expressionsLock.withLock {
            if expressions.count >= 64 { expressions.removeAll() }
            expressions[key] = e
        }
        return e
    }

    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"\{(name|ext|created|modified|exif|width|height|artist|album|title)(?::([^{}]+))?\}"#)

    private static func tokens(_ text: String, entry: BatchRenameEntry, stem: String, ext: String, timeZone: TimeZone, regexReplacement: Bool = false)
        throws -> String
    {
        guard text.contains("{") else { return text }
        let regex = tokenExpression
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let key = (text as NSString).substring(with: match.range(at: 1))
            let value: String
            if key == "name" {
                value = stem
            } else if key == "ext" {
                value = ext
            } else if ["created", "modified", "exif"].contains(key) {
                let date = key == "created" ? entry.created : key == "modified" ? entry.modified : entry.exifDate
                guard let date else { throw BatchRenameError.invalid("\(key) date is unavailable for “\(entry.url.lastPathComponent)”.") }
                let format = match.range(at: 2).location == NSNotFound ? "yyyy-MM-dd" : (text as NSString).substring(with: match.range(at: 2))
                var calendar = Calendar(identifier: .gregorian)
                calendar.locale = Locale(identifier: "en_US_POSIX")
                calendar.timeZone = timeZone
                value = FileFormat.formatter(format, calendar: calendar).string(from: date)
            } else {
                guard let metadata = entry.metadata[key] else {
                    throw BatchRenameError.invalid("\(key) metadata is unavailable for “\(entry.url.lastPathComponent)”.")
                }
                value = metadata
            }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: regexReplacement ? NSRegularExpression.escapedTemplate(for: value) : value)
        }
        return output
    }

    /// Pure collision and staging planner. Directory snapshots include hidden files and dangling symlinks.
    /// Keys are parent URL paths. Unicode canonical equivalents always collide; case folding follows each volume.
    public static func plan(
        _ entries: [BatchRenameEntry], names: [Result<String, Error>], existing: [String: [String]], caseSensitive: [String: Bool] = [:],
        token: String = UUID().uuidString
    ) -> BatchRenamePlan {
        plan(entries, names: names, existing: existing, caseSensitive: caseSensitive, token: token, checkCancellation: {})
    }

    public static func plan(
        _ entries: [BatchRenameEntry], names: [Result<String, Error>], existing: [String: [String]], caseSensitive: [String: Bool] = [:],
        token: String = UUID().uuidString, checkCancellation: () throws -> Void
    ) rethrows -> BatchRenamePlan {
        try checkCancellation()
        var rows = try entries.enumerated().map { index, entry -> BatchRenameRow in
            try checkCancellation()
            guard index < names.count else {
                return BatchRenameRow(source: entry.url, proposedName: entry.url.lastPathComponent, problem: "No proposed name.")
            }
            switch names[index] {
            case .success(let name): return BatchRenameRow(source: entry.url, proposedName: name)
            case .failure(let error):
                return BatchRenameRow(source: entry.url, proposedName: entry.url.lastPathComponent, problem: error.localizedDescription)
            }
        }
        func key(_ name: String, parent: String) -> String {
            let n = name.precomposedStringWithCanonicalMapping
            return caseSensitive[parent] == true ? n : n.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        var occupiedNames: [String: Set<String>] = [:]
        let groups = try Dictionary(grouping: rows.indices) {
            try checkCancellation(); return rows[$0].source.deletingLastPathComponent().path
        }
        for (parent, indices) in groups {
            let selected = try Set(
                indices.map {
                    try checkCancellation(); return key(rows[$0].source.lastPathComponent, parent: parent)
                })
            var targets: [String: [Int]] = [:]
            let allNames = try Set(
                (existing[parent] ?? []).map {
                    try checkCancellation(); return key($0, parent: parent)
                })
            occupiedNames[parent] = allNames
            let occupied = allNames.subtracting(selected)
            var sources: Set<String> = []
            for i in indices {
                try checkCancellation()
                let row = rows[i]
                if !sources.insert(key(row.source.lastPathComponent, parent: parent)).inserted {
                    rows[i].problem = "The same source is selected more than once."
                }
                if !FileName.isValid(row.proposedName, for: .local) {
                    rows[i].problem = "Invalid filename (one component, up to 255 UTF-8 bytes)."
                }
                let k = key(row.proposedName, parent: parent)
                targets[k, default: []].append(i)
                if occupied.contains(k) { rows[i].problem = "An unselected item already has this name." }
            }
            for duplicates in targets.values where duplicates.count > 1 {
                for i in duplicates { rows[i].problem = "Several selected items would have this name." }
            }
        }
        // Walk ancestors instead of comparing every pair, so large file selections stay responsive.
        let selectedDirectories = Dictionary(grouping: entries.indices.filter { entries[$0].isDirectory }) {
            entries[$0].url.path.precomposedStringWithCanonicalMapping
        }
        for i in rows.indices {
            try checkCancellation()
            var parent = rows[i].source.deletingLastPathComponent()
            while parent.path != "/" && !parent.path.isEmpty {
                if let ancestors = selectedDirectories[parent.path.precomposedStringWithCanonicalMapping] {
                    rows[i].problem = "Select either this item or its parent folder, not both."
                    for j in ancestors { rows[j].problem = "A selected child is inside this folder." }
                }
                let next = parent.deletingLastPathComponent()
                if next == parent { break }; parent = next
            }
        }
        guard rows.allSatisfy({ $0.problem == nil }) else { return BatchRenamePlan(rows: rows, steps: []) }
        let token = String(token.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        let changed = rows.filter(\.changes)
        var staged: [RenameMove] = [], final: [RenameMove] = []
        var reserved = Set(rows.map { $0.target.path.precomposedStringWithCanonicalMapping.lowercased() })
        for (index, row) in changed.enumerated() {
            try checkCancellation()
            let parent = row.source.deletingLastPathComponent()
            var name = ".porpoise-rename-\(token)-\(index)"
            let used = occupiedNames[parent.path] ?? []
            while used.contains(key(name, parent: parent.path))
                || reserved.contains(parent.appendingPathComponent(name).path.precomposedStringWithCanonicalMapping.lowercased())
            { name += "-" }
            let temporary = parent.appendingPathComponent(name)
            reserved.insert(temporary.path.precomposedStringWithCanonicalMapping.lowercased())
            staged.append(RenameMove(from: row.source, to: temporary)); final.append(RenameMove(from: temporary, to: row.target))
        }
        return BatchRenamePlan(rows: rows, steps: staged + final)
    }
}
