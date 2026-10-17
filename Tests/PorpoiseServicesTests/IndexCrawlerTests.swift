import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The parallel getattrlistbulk crawler on real folders.
struct IndexCrawlerTests {
    @Test func everythingDepthFirstWithSubtreesTogether() throws {
        let s = try Scratch()
        for d in 0..<30 {
            for f in 0..<100 { try s.file("root/d\(d)/sub\(d % 3)/f\(f).txt", "") }
        }
        try s.file("root/top.txt", "")
        let index = IndexCrawler.crawl(s.path("root").path, exclusions: [])
        // root, top, 30 folders with a subfolder each, 3000 files.
        #expect(index.count == 1 + 1 + 60 + 3000)
        // Each folder's entries follow it without a gap (what patches and subtree counts rely on).
        for id in 0..<index.count where index.isDirectory(id) {
            let under = index.countUnderPath(index.path(id))
            for j in id..<(id + under) { #expect(index.path(j).hasPrefix(index.path(id))) }
            if id + under < index.count { #expect(!index.path(id + under).hasPrefix(index.path(id) + "/")) }
        }
        #expect(try index.search(IndexQuery("f99.txt"), limit: .max).count == 30)
        #expect(index.path(0) == s.path("root").path)
    }

    @Test func packagesAreOneItem() throws {
        let s = try Scratch()
        try s.file("root/Thing.app/Contents/Info.plist", "")
        try s.file("root/Pics.photoslibrary/database/x.db", "")
        try s.file("root/my.folder/inside.txt", "")
        let index = IndexCrawler.crawl(s.path("root").path, exclusions: [])
        let names = Set((0..<index.count).map { index.name($0) })
        #expect(names.isSuperset(of: ["Thing.app", "Pics.photoslibrary", "my.folder", "inside.txt"]))
        #expect(!names.contains("Info.plist") && !names.contains("x.db"))
    }

    @Test func contentIsIndexedForTextFiles() throws {
        let s = try Scratch()
        try s.file("root/a.txt", "the quick brown fox")
        try s.file("root/b.txt", "lazy dog")
        try s.file("root/big.txt", String(repeating: "padding ", count: 200_000))  // over 1 MB: read when searched
        try Data([0x66, 0x6f, 0x78, 0x00, 0x01]).write(to: s.path("root/c.bin"))  // binary: read when searched
        let root = s.path("root").path
        let index = IndexCrawler.crawl(root, exclusions: [], content: true)
        let names = index.contentCandidates("brown fox", scope: root).map { index.name($0) }.sorted()
        #expect(names == ["a.txt", "big.txt", "c.bin"])
        #expect(index.contentCandidates("lazy", scope: root).map { index.name($0) }.sorted() == ["b.txt", "big.txt", "c.bin"])
        // Saved and read back.
        let back = try NameIndex(encoded: index.encoded())
        #expect(back.contentCandidates("brown fox", scope: root).count == 3)
    }

    @Test func unreadableFoldersAreReportedAndCancellingStops() throws {
        let s = try Scratch()
        try s.file("root/open/a.txt", "")
        try s.file("root/closed/b.txt", "")
        chmod(s.path("root/closed").path, 0)
        defer { chmod(s.path("root/closed").path, 0o755) }
        var holes: [String] = []
        let index = IndexCrawler.crawl(s.path("root").path, exclusions: [], unreadable: { holes.append($0) })
        #expect(holes == [s.path("root/closed").path])
        #expect(try index.search(IndexQuery("closed")).count == 1)
        #expect(try index.search(IndexQuery("b.txt")).isEmpty)
        let cancelled = IndexCrawler.crawl(s.path("root").path, exclusions: [], cancelled: { true })
        #expect(cancelled.count == 0)
        #expect(IndexCrawler.crawl(s.path("missing").path, exclusions: []).count == 0)
        // A file as the root: just itself.
        #expect(IndexCrawler.crawl(s.path("root/open/a.txt").path, exclusions: []).count == 1)
    }
}
