import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct FolderSearchCandidateTests {
    @Test func nameRejectionEqualsTheSharedPredicate() throws {
        let names = [
            "", "A", "REPORT-2026.txt", ".hidden", "Café", "Cafe\u{301}", "Straße", "İstanbul", "Kelvin", "ﬃ", "Æther", "ＡＢＣ",
            "line\nbreak.txt", "a+b(1).txt", "\u{FEFF}report", "Σίσυφος", "💡idea", "Résumé.PDF",
        ]
        let queries = ["", "a", "report", "cafE", "café", "strasse", "i", "kelvin", "ffi", "æ", "abc", "💡", "line\nbreak", "+b(1)", "Σίσυφος"]
        for contents in [false, true] {
            for text in queries {
                let spec = try SearchSpec(text, contents: contents), candidates = FolderSearchCandidates(spec: spec)
                let discovery = candidates.discoveryPattern.isEmpty ? nil : try NSRegularExpression(pattern: candidates.discoveryPattern)
                for name in names {
                    #expect(candidates.nameMatches(name) == spec.nameMatches(name), "\(text), \(name), contents=\(contents)")
                    if spec.nameMatches(name), let discovery {
                        #expect(discovery.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil)
                    }
                    if !name.isEmpty {
                        #expect(candidates.nameMatches("/scope/" + name) == spec.nameMatches(name))
                        #expect(candidates.nameMatches("/scope/" + name + "/") == spec.nameMatches(name))
                    }
                }
            }
        }
        for text in ["report 2026 ext:txt", "file: size:>1", "regex:^r.*pdf$", "path:scope folder:", "\"cafe annual\"", "unknown:word"] {
            let spec = try SearchSpec(text), candidates = FolderSearchCandidates(spec: spec)
            for name in names { #expect(candidates.nameMatches(name) == spec.nameMatches(name)) }
        }
    }

    @Test func contentVerificationKeepsBoundedPhysicalUtf8AndFirstLineSemantics() throws {
        let s = try Scratch(), spec = try SearchSpec("café", contents: true)
        let candidates = FolderSearchCandidates(spec: spec)
        let file = try s.file("text", "unrelated\n\t CAFÉ first\nCafe\u{301} second\n")
        #expect(candidates.firstLine(in: file.path) == "\t CAFÉ first")
        #expect(candidates.firstLine(in: file.path, isCancelled: { true }) == nil)
        let spanning = try s.file("spanning", String(repeating: "x", count: 65_535) + "café\n")
        #expect(candidates.firstLine(in: spanning.path) == String(repeating: "x", count: 65_535) + "café")
        let boundary = try s.file("boundary", "café" + String(repeating: " ", count: 4_999_995))
        #expect(candidates.firstLine(in: boundary.path) != nil)
        var checks = 0
        #expect(
            candidates.firstLine(
                in: spanning.path,
                isCancelled: {
                    checks += 1; return checks > 1
                }) == nil)
        #expect(candidates.firstLine(in: try s.file("none", "tea").path) == nil)
        #expect(candidates.firstLine(in: try s.file("nul", "café\0").path) == nil)
        let invalid = try s.file("invalid")
        try Data([0xFF, 0x63, 0x61, 0x66, 0x65]).write(to: invalid)
        #expect(candidates.firstLine(in: invalid.path) == nil)
        #expect(candidates.firstLine(in: try s.file("large", String(repeating: "x", count: 5_000_001)).path) == nil)
        #expect(candidates.firstLine(in: try s.folder("folder").path) == nil)
        #expect(candidates.firstLine(in: s.path("missing").path) == nil)
        try s.symlink("link", to: "text")
        #expect(candidates.firstLine(in: s.path("link").path) == nil)
        let fifo = s.path("fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(candidates.firstLine(in: fifo) == nil)
        // Grow after the initial fstat, while the already-open reader still owns the physical file.
        for size in [65_540, 5_000_001] {
            let growing = try s.file("growing-\(size)")
            let writer = try FileHandle(forWritingTo: growing)
            defer { try? writer.close() }
            var grew = false
            let data = Data(("café" + String(repeating: "x", count: size - 5)).utf8)
            let line = candidates.firstLine(in: growing.path) {
                if !grew { try? writer.write(contentsOf: data); grew = true }
                return false
            }
            #expect((line != nil) == (size <= 5_000_000))
        }
    }

    @Test func boundedParallelSearchMatchesSerialVerification() async throws {
        let tools = FolderSearch.Tools(fd: TestPaths.repo.appendingPathComponent("build/search-tools/fd").path)
        try #require(FileManager.default.isExecutableFile(atPath: tools.fd))
        let s = try Scratch()
        try s.file(".gitignore", "ignored/\n")
        try s.file("ignored/café.txt", "name match")
        try s.file(".hidden/one.txt", "tea\n  CAFÉ first\ncafé second")
        try s.file(".git/two.txt", "Cafe\u{301} first")
        try s.file("ext:pdf.txt", "name only")
        try s.file("a+b(1).txt", "name only")
        try s.file("line\nbreak.txt", "name only")
        try s.file("other.txt", "ext:pdf is literal\n")
        try s.file("Report Maker.app/Contents/hidden.txt", "café ext:pdf")
        try s.file("Report Maker.app/Contents/Info.plist", "x")
        try s.folder("café-folder")
        try s.symlink("café-link", to: "other.txt")
        try s.symlink("text-link", to: ".hidden/one.txt")
        for i in 0..<100 { try s.file("many/\(i).txt", i % 3 == 0 ? "café \(i)" : "unrelated") }
        let all = try Shell.run(tools.fd, ["--hidden", "--no-ignore", "--absolute-path", "--print0", "--", "", s.url.path])
        #expect(all.status == 0)
        let paths = String(decoding: all.out, as: UTF8.self).split(separator: "\0").map(String.init)
        for (text, contents) in [
            ("café", true), ("ext:pdf", true), ("report", true), ("café ext:txt", false), ("folder:", false), ("regex:^.*link$", false),
            ("+b(1)", false), ("line\nbreak", false),
        ] {
            let spec = try SearchSpec(text, contents: contents)
            // The old serial verification path: metadata first, shared predicate, bounded physical reads.
            var expected: Set<String> = [], expectedLines: [String: String] = [:]
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard !url.path.contains(".app/"), let item = FileItem.load(url),
                    !(contents && item.isBrowsableFolder), spec.metadataMatches(item)
                else { continue }
                if spec.nameMatches(item.name) {
                    expected.insert(item.url.path)
                } else if contents, let value = IndexFileText.read(path, limit: 5_000_000),
                    let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: { spec.contentMatches(String($0)) })
                {
                    expected.insert(path); expectedLines[path] = FolderSearch.snippet(String(line), around: text)
                }
            }
            var result: ([FileItem], [URL: String])?
            let search = FolderSearch(spec: spec, scope: s.url, limit: 1000, tools: tools) { items, lines, done in
                if done { result = (items, lines) }
            }
            search.start()
            defer { search.stop() }
            try #require(await eventually { result != nil })
            #expect(Set(result!.0.map(\.url.path)) == expected, "\(text), contents=\(contents)")
            #expect(Dictionary(uniqueKeysWithValues: result!.1.map { ($0.key.path, $0.value) }) == expectedLines)
        }
        var result: [FileItem]?
        let limited = FolderSearch(spec: try SearchSpec("café", contents: true), scope: s.url, limit: 7, tools: tools) { items, _, done in
            if done { result = items }
        }
        limited.start()
        try #require(await eventually { result != nil })
        #expect(result!.count == 7 && Set(result!.map(\.url)).count == 7)
    }
}
