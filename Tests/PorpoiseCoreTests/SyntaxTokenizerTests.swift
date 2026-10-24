import Foundation
import PorpoiseCore
import Testing

@Suite struct SyntaxTokenizerTests {
    func tokens(_ text: String, _ language: SyntaxLanguage) throws -> [(String, SyntaxToken.Kind)] {
        let result = try SyntaxTokenizer.tokenize(text, language: language)
        let ns = text as NSString
        return result.spans.map { (ns.substring(with: $0.range), $0.kind) }
    }
    @Test func detectsAllRequestedLanguagesWithoutReadingFiles() {
        let samples: [(String, SyntaxLanguage)] = [
            ("x.swift", .swift), ("x.c", .c), ("x.cpp", .cpp), ("x.mm", .objectiveC), ("x.py", .python),
            ("x.js", .javascript), ("x.ts", .typescript), ("x.json", .json), ("x.yml", .yaml), ("x.toml", .toml),
            ("x.html", .html), ("x.xml", .xml), ("x.css", .css), ("x.sh", .shell), ("x.go", .go),
            ("x.rs", .rust), ("x.java", .java), ("x.kt", .kotlin), ("x.rb", .ruby), ("x.md", .markdown),
            ("x.sql", .sql), ("x.lua", .lua), (".zshrc", .shell), ("README", .markdown),
        ]
        for (file, language) in samples { #expect(SyntaxLanguage.detect(filename: file) == language) }
        #expect(SyntaxLanguage.detect(filename: "script", prefix: "#!/usr/bin/env -S python3 -u\nprint(1)") == .python)
        #expect(SyntaxLanguage.detect(filename: "unknown.bin") == nil)
        #expect(SyntaxLanguage.detect(filename: "notes.txt") == .plain)
    }
    @Test func stringsProtectCommentMarkersAndOffsetsRemainUTF16Correct() throws {
        let text = "let 🐬 = \"// not a comment 日本語\" // real\n"
        let values = try tokens(text, .swift)
        #expect(values.contains { $0.0 == "let" && $0.1 == .keyword })
        #expect(values.contains { $0.0 == "\"// not a comment 日本語\"" && $0.1 == .string })
        #expect(values.filter { $0.1 == .comment }.map(\.0) == ["// real"])
    }
    @Test func nestedCommentsMultilineAndRawStringsAreBounded() throws {
        let comment = "/* first /* nested */ last */"
        #expect(try tokens(comment + " let value = 1", .swift).first?.0 == comment)
        let raw = ##"let text = #"literal \" // still string"#"##
        let rawTokens = try tokens(raw, .swift)
        #expect(rawTokens.filter { $0.1 == .string }.count == 1)
        #expect(!rawTokens.contains { $0.1 == .comment })
        let python = "def f():\n  text = \"\"\"line1\n# inside string\"\"\"\n  return True\n"
        #expect(try tokens(python, .python).filter { $0.1 == .comment }.isEmpty)
        #expect(try tokens("/* unfinished", .c).last?.0 == "/* unfinished")
    }
    @Test func dataAndMarkupHaveKeysTagsAndLiteralValues() throws {
        #expect(
            try tokens(#"{"name": "value", "enabled": true, "count": -1.2e-3}"#, .json).filter { $0.1 == .key }.map(\.0) == [
                #""name""#, #""enabled""#, #""count""#,
            ])
        #expect(try tokens("enabled: true # note", .yaml).contains { $0.0 == "enabled" && $0.1 == .key })
        #expect(try tokens("enabled = true", .toml).contains { $0.0 == "enabled" && $0.1 == .key })
        #expect(try tokens("<div class=\"main\">hello</div>", .html).contains { $0.0 == "class" && $0.1 == .attribute })
        #expect(try tokens("<!-- comment -->", .xml).first?.1 == .comment)
        #expect(try tokens("# Header\n`code`", .markdown).contains { $0.1 == .heading })
        #expect(try tokens("select name from items where id = 42 -- comment", .sql).contains { $0.0 == "select" && $0.1 == .keyword })
    }
    @Test func numericPrefixesDoNotConsumeIdentifiersAndRustLifetimesDoNotSwallowCode() throws {
        let values = try tokens("let x = 42abc; let y = 0xFF; let z = -1.2e-3", .swift)
        #expect(values.filter { $0.1 == .number }.map(\.0) == ["42", "0xFF", "-1.2e-3"])
        let rust = try tokens("fn borrow<'a>(s: &'a str) -> char { '🐬' }", .rust)
        #expect(rust.filter { $0.1 == .attribute }.map(\.0) == ["'a", "'a"])
        #expect(rust.filter { $0.1 == .string }.map(\.0) == ["'🐬'"])
    }

    @Test func everySpanIsOrderedNonoverlappingAndInsideInput() throws {
        let corpus = ["", "🐬é", "'\\'", String(repeating: "#", count: 10000), String(repeating: "/* nested */\n", count: 1000)]
        for language in SyntaxLanguage.allCases {
            for text in corpus {
                let result = try SyntaxTokenizer.tokenize(text, language: language, maximumTokens: 50)
                var last = 0
                for span in result.spans {
                    #expect(span.range.location >= last)
                    #expect(span.range.length > 0)
                    #expect(NSMaxRange(span.range) <= text.utf16.count)
                    last = NSMaxRange(span.range)
                }
                #expect(result.spans.count <= 50)
            }
        }
    }
}
