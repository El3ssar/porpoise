import Foundation
import Testing

@testable import PorpoiseCore

/// The columnar index's search engine: parallel scans split into parts, path and regex conditions, the trigram
/// content index, and what's saved.
struct NameIndexEngineTests {
    /// Enough entries that the scan is split across cores; every 7th has the word, some twice in one name.
    func big() -> (NameIndex, expected: [Int]) {
        var index = NameIndex()
        let root = index.append(name: "/big", directory: true)
        var dir = root
        var expected: [Int] = []
        for i in 0..<60_000 {
            if i % 5000 == 0 { dir = index.append(name: "Folder \(i)", parent: root, directory: true) }
            let hit = i % 7 == 0
            let id = index.append(name: hit ? "aXyzbxyz\(i).txt" : "plain\(i).md", parent: dir, size: Int64(i))
            if hit { expected.append(Int(id)) }
        }
        return (index, expected)
    }

    @Test func partsFindEveryHitInOrder() throws {
        let (index, expected) = big()
        #expect(try index.search(IndexQuery("xyz"), limit: .max) == expected)
        // The limit keeps the first ones in crawl order, whichever part found them.
        #expect(try index.search(IndexQuery("xyz"), limit: 1000) == Array(expected.prefix(1000)))
        // Without a word: every entry checked.
        let small = try index.search(IndexQuery("size:<70 file:"), limit: .max)
        #expect(small.map { index.name($0) } == (0..<70).map { $0 % 7 == 0 ? "aXyzbxyz\($0).txt" : "plain\($0).md" })
        #expect(try index.search(IndexQuery("ext:txt"), limit: .max) == expected)
        #expect(try index.search(IndexQuery("xyz"), scope: "/big/Folder 5000", limit: .max).count == 714)
        #expect(try index.search(IndexQuery("xyz"), limit: .max, excluding: ["/big/Folder 0", "/big/Folder 55000"]).count == expected.count - 1429)
    }

    @Test func pathsAcrossSlashesAndRoots() throws {
        var index = NameIndex()
        let root = index.append(name: "/Users/Me", directory: true)
        let photos = index.append(name: "Photos", parent: root, directory: true)
        let y = index.append(name: "2024", parent: photos, directory: true)
        index.append(name: "IMG_1.JPG", parent: y)
        index.append(name: "notes.txt", parent: root)
        func names(_ q: String) throws -> [String] { try index.search(IndexQuery(q)).map { index.name($0) } }
        #expect(try names("path:photos/2024") == ["2024", "IMG_1.JPG"])
        #expect(try names("path:s/20") == ["2024", "IMG_1.JPG"])
        #expect(try names("path:/users/me/notes") == ["notes.txt"])
        // The root's own path counts for path:, not for words.
        #expect(try names("path:users file:") == ["IMG_1.JPG", "notes.txt"])
        #expect(try names("users").isEmpty)
        #expect(try names("path:2024/") == ["IMG_1.JPG"])
        #expect(index.id(of: "/Users/Me/Photos/2024/IMG_1.JPG") == 3)
        #expect(index.id(of: "/Users/Me/Photos/2025") == nil)
        #expect(index.id(of: "/Users/Me") == 0)
        #expect(index.countUnderPath("/Users/Me/Photos") == 3)
        #expect(try index.search(IndexQuery("img"), scope: "/Users").count == 1)  // a scope above the root
        #expect(try index.search(IndexQuery("img"), scope: "/Elsewhere").isEmpty)
    }

    @Test func regexesRunAsPOSIXWherePossible() throws {
        #expect(SearchScratch.posixPattern(#"^img_\d+\.jpg$"#) == #"^img_[0-9]+\.jpg$"#)
        #expect(SearchScratch.posixPattern(#"[\]x]"#) == nil)
        #expect(SearchScratch.posixPattern(#"[]a]+\s\w"#) == "[]a]+[[:space:]][[:alnum:]_]")
        #expect(SearchScratch.posixPattern("(?i)x") == nil)
        #expect(SearchScratch.posixPattern("a+?") == nil)
        #expect(SearchScratch.posixPattern(#"\bword"#) == nil)
        #expect(SearchScratch.posixPattern("[abc") == nil)
        #expect(SearchScratch.posixPattern(#"a\-b\/c"#) == "a-b/c")
        // Both ways give what NSRegularExpression gives on the original name.
        var index = NameIndex()
        let root = index.append(name: "/r", directory: true)
        let names = ["IMG_0001.JPG", "img_12.jpg", "café 2.txt", "Café.TXT", "x.jpg", "IMG_.jpg", "a b", "a-b"]
        for n in names { index.append(name: n, parent: root) }
        for pattern in [#"^img_\d+\.jpg$"#, "^caf", #"\s"#, #"^(?:img)"#, "TXT$", #"\bb"#, "a-b"] {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let expected = names.filter { n in
                let f = n
                return re.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil
            }
            #expect(try index.search(IndexQuery("regex:" + pattern)).map { index.name($0) } == expected, "\(pattern)")
        }
    }

    @Test func regexUsesOriginalUnicodeNames() throws {
        var index = NameIndex()
        let root = index.append(name: "/r", directory: true)
        let names = ["Résumé.txt", "Resume.txt", "RÉSUMÉ.txt", "résumé[1].txt", "日本語.txt", "e\u{301}.txt"]
        for name in names { index.append(name: name, parent: root) }
        for pattern in ["^Résumé", "^R[éÉ]sumé", #"résumé\[1\]"#, #"\p{Han}+"#, "^e\u{301}"] {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let expected = names.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            #expect(try index.search(IndexQuery("regex:" + pattern)).map { index.name($0) } == expected, "\(pattern)")
        }
    }

    @Test func extensionsAsPathExtension() throws {
        var index = NameIndex()
        let root = index.append(name: "/r", directory: true)
        for n in ["a.tar.gz", ".bashrc", "noext", "trailing.", "x.GZ"] { index.append(name: n, parent: root) }
        index.append(name: "dir.gz", parent: root, directory: true)
        #expect(try index.search(IndexQuery("ext:gz")).map { index.name($0) } == ["a.tar.gz", "x.GZ"])
        #expect(try index.search(IndexQuery("ext:.")).map { index.name($0) } == [".bashrc", "noext", "trailing."])
    }

    @Test func contentPostings() throws {
        var index = NameIndex()
        let root = index.append(name: "/c", directory: true)
        index.append(name: "a.txt", parent: root, content: "The quick brown fox")
        index.append(name: "b.txt", parent: root, content: "a lazy dog, quick")
        index.append(name: "c.bin", parent: root)  // not indexed: always a candidate
        index.append(name: "d.txt", parent: root, content: "Ça va très bien")
        let link = index.append(name: "link", parent: root, symlink: true)
        _ = link
        #expect(index.contentCandidates("quick", scope: "/c") == [1, 2, 3])
        #expect(index.contentCandidates("QUICK BROWN", scope: "/c") == [1, 3])
        #expect(index.contentCandidates("tres", scope: "/c") == [3, 4])
        #expect(index.contentCandidates("zzzzz", scope: "/c") == [3])
        // Too short to filter: every file.
        #expect(index.contentCandidates("qu", scope: "/c") == [1, 2, 3, 4])
        #expect(index.contentCandidates("quick", scope: "/elsewhere").isEmpty)
        #expect(index.contentCandidates("quick", scope: "/c", cancelled: { true }).isEmpty)
        // Saved and read back, and still growing afterwards.
        var back = try NameIndex(encoded: index.encoded())
        #expect(back.contentCandidates("quick brown", scope: "/c") == [1, 3])
        let copy = back
        back.append(name: "e.txt", parent: 0, content: "quick brown bear")
        #expect(back.contentCandidates("quick brown", scope: "/c") == [1, 3, 6])
        #expect(copy.contentCandidates("quick brown", scope: "/c") == [1, 3])
        #expect(index.storageBytes > 0)
    }

    @Test func trigramsAndPostingsAtScale() {
        let c = ContentIndex()
        for id in 0..<5000 { c.add(UInt32(id), grams: Array("w\(id % 100)x".utf8).withUnsafeBufferPointer { ContentIndex.trigrams($0) }) }
        // "w42x" is in ids 42, 142, …: delta-encoded lists decode exactly.
        #expect(c.candidates(Array("w42x".utf8)) == (0..<50).map { UInt32($0 * 100 + 42) })
        #expect(c.candidates(Array("w4".utf8)) == nil)
        #expect(Array("aaaa".utf8).withUnsafeBufferPointer { ContentIndex.trigrams($0) } == [0x61_6161])
    }

    @Test func damagedFilesAreRefused() throws {
        var index = NameIndex()
        let root = index.append(name: "/c", directory: true)
        index.append(name: "a.txt", parent: root, content: "hello world")
        let valid = index.encoded()
        #expect(try NameIndex(encoded: valid).count == 2)
        for n in stride(from: 0, to: valid.count, by: 7) { #expect(throws: NameIndex.Corrupt.self) { try NameIndex(encoded: valid.prefix(n)) } }
        var extra = valid
        extra.append(0)
        #expect(throws: NameIndex.Corrupt.self) { try NameIndex(encoded: extra) }
        var old = valid
        old[7] = UInt8(ascii: "1")  // the previous format is built again
        #expect(throws: NameIndex.Corrupt.self) { try NameIndex(encoded: old) }
    }
}

/// What the search bar says while an operator is typed.
struct IndexQueryHintTests {
    @Test func hintsForOperators() {
        #expect(IndexQuery.hint(for: "") == nil)
        #expect(IndexQuery.hint(for: "report") == nil)
        #expect(IndexQuery.hint(for: "report ") == nil)
        #expect(IndexQuery.hint(for: "report si")?.hasPrefix("Type size: to filter: size:>10mb") == true)
        #expect(IndexQuery.hint(for: "x") == nil)  // one letter says nothing
        #expect(IndexQuery.hint(for: "a size:")?.hasPrefix("size:>10mb") == true)
        #expect(IndexQuery.hint(for: "a size:>10mb") == nil)  // valid: nothing to add
        #expect(IndexQuery.hint(for: "size:>10zz")?.hasPrefix("Invalid search: size:>10zz — size:") == true)
        #expect(IndexQuery.hint(for: "DM:")?.hasPrefix("dm:today") == true)
        #expect(IndexQuery.hint(for: "regex:[")?.hasSuffix("a regular expression on the name") == true)
        #expect(IndexQuery.hint(for: "foo:bar") == nil)
    }

    @Test func completions() {
        #expect(IndexQuery.completions(for: "s") == ["size:"])
        #expect(IndexQuery.completions(for: "F") == ["folder:", "file:"])
        #expect(IndexQuery.completions(for: "size:").isEmpty)
        #expect(IndexQuery.completions(for: "").count == IndexQuery.operators.count)
    }
}
