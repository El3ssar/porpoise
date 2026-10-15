import Foundation

extension IndexQuery {
    /// The operators, as typed, for completion.
    public static let operators = ["ext:", "path:", "size:", "dm:", "folder:", "file:", "regex:"]

    private static let usage: [String: String] = [
        "ext": "ext:pdf;docx — files with any of these extensions",
        "path": "path:Projects/app — the whole path contains this",
        "size": "size:>10mb, size:<=1kb, size:5mb — units b, kb, mb, gb, tb",
        "dm": "dm:today, dm:>=2026-01-01, dm:<2025-06-30 — date modified",
        "folder": "folder: only folders (folder:false: no folders)",
        "file": "file: only files (file:false: no files)",
        "regex": #"regex:^IMG_\d+\.jpe?g$ — a regular expression on the name"#,
    ]

    /// A line for the status bar about the word being typed (the last of `text`): how to use the operator it starts,
    /// or what's wrong with it. Nil for plain words.
    public static func hint(for text: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let last = text.split(whereSeparator: \.isWhitespace).last.map(String.init), !text.last!.isWhitespace else {
            return nil
        }
        guard let colon = last.firstIndex(of: ":") else {
            // The start of an operator's name: say what it does.
            let word = last.lowercased()
            guard word.count >= 2, let op = operators.first(where: { $0.hasPrefix(word) }) else { return nil }
            return "Type \(op) to filter: " + usage[String(op.dropLast())]!
        }
        let key = last[..<colon].lowercased()
        guard let use = usage[key] else { return nil }
        let value = last[last.index(after: colon)...]
        if value.isEmpty { return use }
        do {
            _ = try IndexQuery(last, now: now, calendar: calendar)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription.map { "\($0) — \(use)" } ?? use
        }
    }

    /// Operators starting with `partial` (completion of the word being typed).
    public static func completions(for partial: String) -> [String] {
        let p = partial.lowercased()
        return p.isEmpty ? operators : operators.filter { $0.hasPrefix(p) && $0 != p }
    }
}
