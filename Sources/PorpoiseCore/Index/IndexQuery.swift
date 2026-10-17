import Foundation

/// Everything-style AND query. Fold once at ingestion/query time, independent of the current locale.
public struct IndexQuery: @unchecked Sendable {
    public var terms: [String] = []
    public var paths: [String] = []
    public var extensions: Set<String> = []
    public var directory: Bool?
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var after: TimeInterval?
    public var before: TimeInterval?
    public var regex: NSRegularExpression?

    public enum Invalid: Error, LocalizedError {
        case syntax(String)
        public var errorDescription: String? { if case .syntax(let s) = self { return "Invalid search: \(s)" }; return nil }
    }

    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public init(literal text: String) { terms = [Self.fold(text)] }

    public init(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for c in text {
            if escaped {
                token.append(c); escaped = false
            } else if c == "\\" && quoted {
                escaped = true
            } else if c == "\"" {
                quoted.toggle()
            } else if c.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(c)
            }
        }
        guard !quoted && !escaped else { throw Invalid.syntax("unclosed quote") }
        if !token.isEmpty { tokens.append(token) }
        for token in tokens {
            guard let colon = token.firstIndex(of: ":") else { terms.append(Self.fold(token)); continue }
            let key = token[..<colon].lowercased(), value = String(token[token.index(after: colon)...])
            switch key {
            case "ext":
                let values = value.split(whereSeparator: { $0 == ";" || $0 == "," }).map {
                    Self.fold(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
                guard !values.isEmpty else { throw Invalid.syntax(token) }
                extensions.formUnion(values)
            case "path": guard !value.isEmpty else { throw Invalid.syntax(token) }; paths.append(Self.fold(value))
            case "folder", "file":
                guard value.isEmpty || value == "true" || value == "false" else { throw Invalid.syntax(token) }
                let isTrue = value != "false"
                directory = key == "folder" ? isTrue : !isTrue
            case "regex": regex = try NSRegularExpression(pattern: value, options: [.caseInsensitive])
            case "size":
                let (op, number) = Self.comparison(value)
                let units: [(String, Double)] = [("kb", 1024), ("mb", 1048576), ("gb", 1073741824), ("tb", 1099511627776), ("b", 1)]
                let lower = number.lowercased()
                let unit = units.first { lower.hasSuffix($0.0) }
                let numeric = unit.map { String(lower.dropLast($0.0.count)) } ?? lower
                guard let n = Double(numeric), n >= 0, n.isFinite, n * (unit?.1 ?? 1) < Double(Int64.max) else { throw Invalid.syntax(token) }
                let size = Int64(n * (unit?.1 ?? 1))
                switch op {
                case ">": minimumSize = size + 1
                case ">=": minimumSize = size
                case "<": maximumSize = size - 1
                case "<=": maximumSize = size
                default: minimumSize = size; maximumSize = size
                }
            case "dm":
                let (op, date) = Self.comparison(value)
                let start: Date
                if date.lowercased() == "today" {
                    start = calendar.startOfDay(for: now)
                } else {
                    guard let parsed = FileFormat.posixDate(date, format: "yyyy-MM-dd", timeZone: calendar.timeZone, calendar: calendar),
                        FileFormat.posixString(parsed, format: "yyyy-MM-dd", timeZone: calendar.timeZone, calendar: calendar) == date
                    else { throw Invalid.syntax(token) }
                    start = parsed
                }
                let end = calendar.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince1970
                switch op {
                case ">": after = end
                case ">=": after = start.timeIntervalSince1970
                case "<": before = start.timeIntervalSince1970
                case "<=": before = end
                default: after = start.timeIntervalSince1970; before = end
                }
            default: terms.append(Self.fold(token))  // A colon in a filename remains literal.
            }
        }
    }

    private static func comparison(_ value: String) -> (String, String) {
        for op in [">=", "<=", ">", "<", "="] where value.hasPrefix(op) { return (op, String(value.dropFirst(op.count))) }
        return ("=", value)
    }
}
