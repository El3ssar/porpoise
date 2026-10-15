import Foundation
import Testing

@testable import PorpoiseCore

struct IndexCoverageTests {
    @Test func invalidQueryDescribesItself() {
        #expect(IndexQuery.Invalid.syntax("size:wrong").localizedDescription == "Invalid search: size:wrong")
        #expect(throws: IndexQuery.Invalid.self) { try IndexQuery("\"open") }
        #expect(throws: IndexQuery.Invalid.self) { try IndexQuery("\"ends in escape\\") }
        #expect(throws: IndexQuery.Invalid.self) { try IndexQuery("path:") }
    }

    @Test func escapesInsideQuotesAreLiteral() throws {
        #expect(try IndexQuery(#""say \"hi\" now""#).terms == [#"say "hi" now"#])
        #expect(try IndexQuery(#"back\slash"#).terms == [#"back\slash"#])
    }

    @Test func everySizeComparison() throws {
        let kb = try IndexQuery("size:>=1kb")
        #expect(kb.minimumSize == 1024 && kb.maximumSize == nil)
        let below = try IndexQuery("size:<10")
        #expect(below.maximumSize == 9 && below.minimumSize == nil)
        let exact = try IndexQuery("size:=2b")
        #expect(exact.minimumSize == 2 && exact.maximumSize == 2)
        let plain = try IndexQuery("size:5")
        #expect(plain.minimumSize == 5 && plain.maximumSize == 5)
    }

    @Test func everyDateComparison() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day: TimeInterval = 1_767_225_600  // 2026-01-01 00:00 UTC
        let from = try IndexQuery("dm:>=2026-01-01", calendar: utc)
        #expect(from.after == day && from.before == nil)
        let until = try IndexQuery("dm:<2026-01-01", calendar: utc)
        #expect(until.before == day && until.after == nil)
        let through = try IndexQuery("dm:<=2026-01-01", calendar: utc)
        #expect(through.before == day + 86400 && through.after == nil)
        let on = try IndexQuery("dm:2026-01-01", calendar: utc)
        #expect(on.after == day && on.before == day + 86400)
    }

    @Test func entryAndCanonicalEdgeCases() {
        #expect(IndexPath.entry("/") == "/")
        #expect(IndexPath.entry("/top-level-entry") == "/top-level-entry")
        let tmp = IndexPath.canonical(NSTemporaryDirectory())
        #expect(IndexPath.entry(NSTemporaryDirectory() + "leaf/") == tmp + "/leaf")
        // A missing top-level folder keeps its spelling below the root.
        let missing = "/porpoise-missing-\(UUID().uuidString)"
        #expect(IndexPath.canonical(missing + "/child") == missing + "/child")
        // Relative paths are taken from the current directory.
        let cwd = IndexPath.canonical(FileManager.default.currentDirectoryPath)
        #expect(IndexPath.canonical("porpoise-relative-\(missing.dropFirst())") == cwd + "/porpoise-relative-\(missing.dropFirst())")
    }

    @Test func storageBytesCountRecordsAndNames() {
        var index = NameIndex()
        #expect(index.storageBytes == 0)
        index.append(name: "/root", directory: true)
        let one = index.storageBytes
        // A fixed part plus the original and folded names, each ending in a NUL ("/root\0" and "root\0").
        let fixed = one - 11
        #expect(fixed > 0)
        // A name that is already folded is stored once.
        index.append(name: "longer-name.txt", parent: 0)
        #expect(index.storageBytes - one == fixed + "longer-name.txt".utf8.count + 1)
    }
}
