import Foundation

public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: String, Sendable { case keyword, type, string, comment, number, key, tag, heading, attribute }
    /// UTF16 offsets match AppKit text storage; spans never overlap or escape the input.
    public let range: NSRange
    public let kind: Kind
}

public struct SyntaxTokens: Sendable {
    public let spans: [SyntaxToken]
    public let limited: Bool
}

public enum SyntaxTokenizer {
    public static func tokenize(_ text: String, language: SyntaxLanguage, maximumTokens: Int = 30000) throws -> SyntaxTokens {
        guard language != .plain else { return SyntaxTokens(spans: [], limited: false) }
        var scanner = Scanner(text, language: language, limit: max(0, maximumTokens))
        return try scanner.scan()
    }

    private struct Scanner {
        let units: [UInt16]
        let language: SyntaxLanguage
        let limit: Int
        let keywords: Set<String>
        let supportsSlashComments: Bool
        let isMarkup: Bool
        let supportsNestedComments: Bool
        let supportsHashComments: Bool
        let supportsDashComments: Bool
        let supportsBacktickStrings: Bool
        let supportsTripleStrings: Bool
        let literalSingleQuotes: Bool
        let doubledQuotes: Bool
        let colonKeys: Bool
        let supportsAtAttributes: Bool
        let hyphenIdentifiers: Bool
        var i = 0
        var spans: [SyntaxToken] = []
        var limited = false
        init(_ text: String, language: SyntaxLanguage, limit: Int) {
            units = Array(text.utf16); self.language = language; self.limit = limit
            keywords = SyntaxTokenizer.words(for: language)
            isMarkup = [.html, .xml].contains(language)
            supportsNestedComments = [.swift, .rust, .kotlin].contains(language)
            supportsHashComments = [.python, .shell, .ruby, .yaml, .toml].contains(language)
            supportsDashComments = [.sql, .lua].contains(language)
            supportsBacktickStrings = [.javascript, .typescript, .go].contains(language)
            supportsTripleStrings = [.swift, .python, .kotlin, .toml].contains(language)
            literalSingleQuotes = [.toml, .sql, .yaml].contains(language)
            doubledQuotes = [.sql, .yaml].contains(language)
            colonKeys = [.yaml, .css].contains(language)
            supportsAtAttributes = [.swift, .objectiveC, .python, .java, .kotlin].contains(language)
            hyphenIdentifiers = [.css, .html, .xml].contains(language)
            supportsSlashComments = [.swift, .c, .cpp, .objectiveC, .javascript, .typescript, .css, .go, .rust, .java, .kotlin, .json].contains(
                language)
        }
        func matches(_ literal: String, at offset: Int) -> Bool {
            guard offset >= 0, offset + literal.utf16.count <= units.count else { return false }
            for (index, unit) in literal.utf16.enumerated() where units[offset + index] != unit { return false }
            return true
        }
        func whitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func digit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func identifier(_ c: UInt16) -> Bool { c == 95 || c >= 65 && c <= 90 || c >= 97 && c <= 122 || c >= 128 }
        func nextNonspace(_ offset: Int) -> Int {
            var next = offset
            while next < units.count && whitespace(units[next]) { next += 1 }
            return next
        }
        mutating func emit(_ start: Int, _ kind: SyntaxToken.Kind) {
            guard i > start else { return }
            if spans.count == limit { limited = true; return }
            spans.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: kind))
        }
        mutating func throughLine() { while i < units.count && units[i] != 10 && units[i] != 13 { i += 1 } }
        mutating func block(_ open: String, _ close: String, nested: Bool) throws {
            let start = i, openCount = open.utf16.count, closeCount = close.utf16.count
            i += openCount
            var depth = 1
            while i < units.count {
                if i % 4096 == 0 { try Task.checkCancellation() }
                if matches(close, at: i) {
                    i += closeCount; depth -= 1; if depth == 0 { break }
                } else if nested && matches(open, at: i) {
                    depth += 1; i += openCount
                } else {
                    i += 1
                }
            }
            emit(start, .comment)
        }
        mutating func quoted(_ delimiter: String, escaped: Bool = true, doubled: Bool = false, start: Int? = nil) throws {
            let lower = start ?? i, count = delimiter.utf16.count
            i += count
            while i < units.count {
                if i % 4096 == 0 { try Task.checkCancellation() }
                if escaped && units[i] == 92 { i = min(units.count, i + 2); continue }
                if matches(delimiter, at: i) {
                    i += count
                    if doubled && matches(delimiter, at: i) { i += count; continue }
                    break
                }
                i += 1
            }
            let next = nextNonspace(i)
            let isKey = [.json, .yaml].contains(language) && next < units.count && units[next] == 58
            emit(lower, isKey ? .key : .string)
        }
        mutating func consumeNumber() {
            if units[i] == 45 { i += 1 }
            var radix = 10
            if i + 1 < units.count && units[i] == 48 {
                if [UInt16(120), 88].contains(units[i + 1]) {
                    radix = 16; i += 2
                } else if [UInt16(98), 66].contains(units[i + 1]) {
                    radix = 2; i += 2
                } else if [UInt16(111), 79].contains(units[i + 1]) {
                    radix = 8; i += 2
                }
            }
            func valid(_ c: UInt16) -> Bool {
                if c == 95 { return true }
                if c >= 48 && c <= 57 { return Int(c - 48) < radix }
                return radix == 16 && (c >= 65 && c <= 70 || c >= 97 && c <= 102)
            }
            while i < units.count && valid(units[i]) { i += 1 }
            if i + 1 < units.count && units[i] == 46 && valid(units[i + 1]) {
                i += 1
                while i < units.count && valid(units[i]) { i += 1 }
            }
            if i < units.count && (radix == 16 ? [UInt16(112), 80] : [UInt16(101), 69]).contains(units[i]) {
                var next = i + 1
                if next < units.count && [UInt16(43), 45].contains(units[next]) { next += 1 }
                if next < units.count && digit(units[next]) {
                    i = next + 1
                    while i < units.count && (digit(units[i]) || units[i] == 95) { i += 1 }
                }
            }
        }

        mutating func scan() throws -> SyntaxTokens {
            while i < units.count && !limited {
                if i % 4096 == 0 { try Task.checkCancellation() }
                let start = i, c = units[i]
                if whitespace(c) { i += 1; continue }
                if language == .markdown {
                    if c == 35 && (i == 0 || units[i - 1] == 10 || units[i - 1] == 13) { throughLine(); emit(start, .heading); continue }
                    if c == 96 {
                        var count = 1
                        while i + count < units.count && units[i + count] == 96 { count += 1 }
                        try quoted(String(repeating: "`", count: count), escaped: false); continue
                    }
                    i += 1; continue
                }
                if isMarkup && matches("<!--", at: i) { try block("<!--", "-->", nested: false); continue }
                if language == .lua && matches("--[[", at: i) { try block("--[[", "]]", nested: false); continue }
                if supportsSlashComments && matches("/*", at: i) {
                    try block("/*", "*/", nested: supportsNestedComments); continue
                }
                let lineComment =
                    supportsSlashComments && matches("//", at: i)
                    || supportsHashComments && c == 35
                    || supportsDashComments && matches("--", at: i)
                if lineComment { throughLine(); emit(start, .comment); continue }
                // Swift raw strings and Rust r###"..."### keep escape characters literal.
                if language == .swift && c == 35 || language == .rust && c == 114 {
                    var next = i + (language == .rust ? 1 : 0), hashes = 0
                    while next < units.count && units[next] == 35 { hashes += 1; next += 1 }
                    if next < units.count && units[next] == 34 && (hashes > 0 || language == .rust) {
                        i = next
                        let triple = language == .swift && matches("\"\"\"", at: i)
                        let open = triple ? "\"\"\"" : "\""
                        let end = open + String(repeating: "#", count: hashes)
                        i += open.utf16.count
                        while i < units.count && !matches(end, at: i) {
                            if i % 4096 == 0 { try Task.checkCancellation() }; i += 1
                        }
                        if matches(end, at: i) { i += end.utf16.count }
                        emit(start, .string); continue
                    }
                    if hashes > 0 { i = next; continue }
                }
                if language == .rust && c == 39 && i + 1 < units.count && identifier(units[i + 1]) {
                    let scalarWidth = (0xD800...0xDBFF).contains(units[i + 1]) ? 2 : 1
                    let close = i + 1 + scalarWidth
                    if close >= units.count || units[close] != 39 {
                        i += 2
                        while i < units.count && (identifier(units[i]) || digit(units[i])) { i += 1 }
                        emit(start, .attribute); continue
                    }
                }
                if c == 34 || c == 39 || c == 96 && supportsBacktickStrings {
                    let quote = String(UnicodeScalar(c)!)
                    let triple = supportsTripleStrings && matches(String(repeating: quote, count: 3), at: i)
                    try quoted(
                        triple ? String(repeating: quote, count: 3) : quote,
                        escaped: !(c == 96 && language == .go) && !(c == 39 && literalSingleQuotes)
                            && !(triple && language == .kotlin),
                        doubled: doubledQuotes)
                    continue
                }
                if isMarkup && c == 60 {
                    i += 1
                    if i < units.count && (units[i] == 47 || units[i] == 33 || units[i] == 63) { i += 1 }
                    while i < units.count && (identifier(units[i]) || digit(units[i]) || units[i] == 45 || units[i] == 58) { i += 1 }
                    emit(start, .tag); continue
                }
                if digit(c) || c == 45 && i + 1 < units.count && digit(units[i + 1]) {
                    consumeNumber()
                    emit(start, .number); continue
                }
                if identifier(c) || c == 64 && supportsAtAttributes {
                    i += 1
                    while i < units.count && (identifier(units[i]) || digit(units[i]) || units[i] == 45 && hyphenIdentifiers) {
                        i += 1
                    }
                    let next = nextNonspace(i)
                    let key = next < units.count && (units[next] == 58 && colonKeys || units[next] == 61 && language == .toml)
                    if key {
                        emit(start, .key)
                    } else if c == 64 {
                        emit(start, .attribute)
                    } else if isMarkup && next < units.count && units[next] == 61 {
                        emit(start, .attribute)
                    } else if i - start <= 128 {
                        let word = String(decoding: units[start..<i], as: UTF16.self)
                        if keywords.contains(language == .sql ? word.lowercased() : word) {
                            emit(start, .keyword)
                        } else if c >= 65 && c <= 90 {
                            emit(start, .type)
                        }
                    }
                    continue
                }
                i += 1
            }
            return SyntaxTokens(spans: spans, limited: limited)
        }
    }

    private static func words(for language: SyntaxLanguage) -> Set<String> {
        let common =
            "if else for while return break continue true false null class struct enum static public private protected import const switch case default try catch throw new void in"
        let specific: String
        switch language {
        case .swift:
            specific =
                "let var func init deinit extension protocol actor async await throws rethrows guard defer nil self Self super some any associatedtype typealias mutating nonmutating override final weak unowned where as is do repeat fallthrough internal fileprivate open package lazy get set willSet didSet"
        case .python:
            specific =
                "def elif lambda and or not None True False pass raise except finally from as with yield assert del global nonlocal async await match case"
        case .javascript, .typescript:
            specific =
                "let var function export default async await extends implements interface type typeof instanceof undefined this super of null delete yield debugger get set namespace declare readonly keyof infer never unknown boolean number string"
        case .c, .cpp, .objectiveC:
            specific =
                "auto bool char double float int long short signed unsigned typedef union volatile extern sizeof inline namespace template typename using virtual friend operator delete constexpr nullptr this noexcept override final include define ifdef endif interface implementation end property synthesize nonatomic strong weak selector"
        case .java, .kotlin:
            specific =
                "package extends implements interface abstract final boolean byte char double float int long short synchronized transient volatile instanceof this super val var fun object data sealed when override companion suspend internal null as is inline reified lateinit where by constructor init"
        case .go: specific = "package func var type map chan range go defer select fallthrough interface nil make len cap append panic recover"
        case .rust:
            specific =
                "fn let mut impl trait pub use mod crate self Self super match loop move ref unsafe extern dyn async await where as in type static const Some None Ok Err"
        case .shell: specific = "then fi elif do done esac function select until export local readonly unset source echo printf test exec exit"
        case .ruby:
            specific =
                "def end module do then elsif unless until begin rescue ensure yield nil self attr_reader attr_accessor require puts alias defined?"
        case .sql:
            specific =
                "select from where join inner outer left right on group by order having limit offset insert into values update set delete create table alter drop primary key foreign references not and or is null as distinct union all count sum begin commit rollback"
        case .lua: specific = "local function end then elseif do until repeat nil and or not require"
        case .json, .yaml, .toml: specific = "true false null True False None inf nan"
        case .css: specific = "important inherit initial unset none auto block flex grid inline absolute relative fixed sticky solid transparent"
        case .html, .xml, .markdown, .plain: specific = ""
        }
        return Set((common + " " + specific).split(separator: " ").map(String.init))
    }
}
