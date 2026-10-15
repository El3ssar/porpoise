import Foundation
import Testing
@testable import PorpoiseCore

struct NameIndexTests {
    func fixture() -> NameIndex {
        var index = NameIndex()
        let root = index.append(name: "/fixture", directory: true)
        let docs = index.append(name: "Documents", parent: root, directory: true)
        index.append(name: "Café Annual Report.PDF", parent: docs, size: 12 * 1048576, modified: 1767225600)
        index.append(name: "budget.txt", parent: docs, size: 100, modified: 1767312000, content: "the annual budget is ready")
        index.append(name: "other.swift", parent: root, size: 200, content: "let hello = 1")
        return index
    }
    @Test func foldedTermsOperatorsAndScope() throws {
        let index = fixture()
        #expect(try index.search(IndexQuery("cafe report ext:pdf size:>10mb file:")).map { index.name($0) } == ["Café Annual Report.PDF"])
        #expect(try index.search(IndexQuery("path:documents ext:txt")).map { index.name($0) } == ["budget.txt"])
        #expect(try index.search(IndexQuery("folder:")).count == 2)
        #expect(try index.search(IndexQuery("file:false")).count == 2)
        #expect(try index.search(IndexQuery("regex:^bud.*txt$")).count == 1)
        #expect(try index.search(IndexQuery("other"), scope: "/fixture/Documents").isEmpty)
        #expect(!NameIndex.contains(path: "/fixture/Documents2", in: "/fixture/Documents"))
        #expect(try index.search(IndexQuery("ext:pdf;txt"), excluding: ["/fixture/Documents"]).isEmpty)
        #expect(try index.search(IndexQuery("\"annual report\"")).count == 1)
    }
    @Test func dateSizeAndSyntax() throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let index = fixture()
        #expect(try index.search(IndexQuery("dm:today", now: Date(timeIntervalSince1970: 1767225601), calendar: utc)).count == 1)
        #expect(try index.search(IndexQuery("dm:>2026-01-01", calendar: utc)).map { index.name($0) } == ["budget.txt"])
        #expect(try index.search(IndexQuery("size:<=100 file:")).map { index.name($0) } == ["budget.txt"])
        for bad in ["size:wrong", "dm:2026-99-01", "folder:maybe", "\"unfinished", "ext:", "regex:["] {
            #expect(throws: (any Error).self) { try IndexQuery(bad) }
        }
        #expect(try IndexQuery("a:b").terms == ["a:b"])
    }
    @Test func persistenceRoundTripAndMalformedInput() throws {
        let original = fixture(), decoded = try NameIndex(encoded: original.encoded())
        #expect(decoded.count == original.count)
        for i in 0..<original.count { #expect(decoded.path(i) == original.path(i)) }
        #expect(decoded.contentCandidates("annual", scope: "/fixture").contains(3))
        #expect(!decoded.contentCandidates("no such phrase", scope: "/fixture").contains(4))
        let valid = original.encoded()
        for n in [0, 7, 23, 25, valid.count - 1] { #expect(throws: NameIndex.Corrupt.self) { try NameIndex(encoded: valid.prefix(n)) } }
        var corrupt = valid
        corrupt[24] = 0; corrupt[25] = 0; corrupt[26] = 0; corrupt[27] = 0 // A root cannot parent itself.
        #expect(throws: NameIndex.Corrupt.self) { try NameIndex(encoded: corrupt) }
    }
    @Test func cancellationAndLimit() throws {
        var index = NameIndex()
        let root = index.append(name: "/fixture", directory: true)
        for n in 0..<3000 { index.append(name: "file\(n)", parent: root) }
        #expect(try index.search(IndexQuery("file"), limit: 17).count == 17)
        #expect(try index.search(IndexQuery("file"), cancelled: { true }).isEmpty)
        #expect(try index.search(IndexQuery("file"), limit: 0).isEmpty)
    }
    @Test func contentBloomHasNoFalseNegativesForUnicodeAndShortQueries() {
        let index = fixture()
        for text in ["annual", "budget", "is", "a", "ready"] { #expect(index.contentCandidates(text, scope: "/fixture").contains(3)) }
    }
}
