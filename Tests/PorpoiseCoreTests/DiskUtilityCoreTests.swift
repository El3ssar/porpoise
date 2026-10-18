import CoreGraphics
import Foundation
import Testing

@testable import PorpoiseCore

struct DiskUtilityCoreTests {
    @Test func standardHashVectorsAndIncrementalUpdates() {
        let expected: [ChecksumAlgorithm: String] = [
            .sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .sha512:
                "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
            .md5: "900150983cd24fb0d6963f7d28e17f72", .sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
        ]
        for algorithm in ChecksumAlgorithm.allCases {
            var h = ChecksumHasher(algorithm); h.update(Data("a".utf8)); h.update(Data("bc".utf8))
            #expect(h.finalize() == expected[algorithm]); #expect(algorithm.accepts(h.finalize().uppercased())); #expect(!algorithm.accepts("zz"))
        }
    }
    @Test func manifestsAcceptGNUAndBSDAndRoundTripOddNames() throws {
        let digest = String(repeating: "ab", count: 32)
        let entries = ["normal.txt", " spaces .txt", "café.txt", "line\nbreak", "back\\slash", "carriage\rreturn"].map {
            ChecksumEntry(path: $0, algorithm: .sha256, digest: digest)
        }
        #expect(try ChecksumManifest.parse(ChecksumManifest.export(entries)) == entries)
        #expect(try ChecksumManifest.parse("# comment\nSHA256 (a (b).txt) = \(digest.uppercased())\r\n").first?.path == "a (b).txt")
        #expect(try ChecksumManifest.parse("\(digest) *binary.txt").first?.path == "binary.txt")
        for invalid in ["", "no checksums", "abcd  file", "\(digest)file", "\(digest)  ", "\\\(digest)  bad\\q"] {
            #expect(throws: ChecksumManifest.Invalid.self) { try ChecksumManifest.parse(invalid) }
        }
    }
    @Test func usageCountsHardLinksOnlyOnceAndAggregatesParents() {
        let root = URL(fileURLWithPath: "/fixture")
        func entry(_ name: String, inode: UInt64, dir: Bool = false) -> DiskEntry {
            DiskEntry(
                url: root.appendingPathComponent(name), identity: DiskIdentity(device: 1, inode: inode), directory: dir, size: dir ? 0 : 100,
                allocated: dir ? 0 : 4096, modified: .distantPast)
        }
        var scan = DiskScan();
        scan.entries = [
            entry("", inode: 1, dir: true), entry("a", inode: 2, dir: true), entry("a/file", inode: 3), entry("alias", inode: 3),
            entry("copy", inode: 4),
        ]
        let tree = UsageTree(scan)
        #expect(tree.nodes[0].logical == 200); #expect(tree.nodes[0].allocated == 8192); #expect(tree.nodes[0].files == 2);
        #expect(tree.hardLinkAliases == 1)
        #expect(tree.nodes.first { $0.url?.lastPathComponent == "a" }?.logical == 100)
    }
    @Test func unorderedUsageLinksNestedParentsAndLexicalHardLinkOwner() {
        func entry(_ path: String, _ inode: UInt64, directory: Bool = false, symlink: Bool = false) -> DiskEntry {
            DiskEntry(
                url: URL(fileURLWithPath: path), identity: DiskIdentity(device: 1, inode: inode), directory: directory,
                symlink: symlink, size: 7, allocated: 16, modified: .distantPast)
        }
        let entries = [
            entry("/fixture/z/alias", 9), entry("/fixture/a/b/file", 9), entry("/fixture/a/b", 3, directory: true),
            entry("/fixture/z/link", 10, symlink: true), entry("/fixture/z/own", 11), entry("/fixture", 1, directory: true),
            entry("/fixture/z", 4, directory: true), entry("/fixture/a", 2, directory: true),
        ]
        for order in [entries, Array(entries.reversed()), entries.shuffled()] {
            var scan = DiskScan(); scan.entries = order
            let tree = UsageTree(scan)
            #expect(tree.nodes[0].logical == 14); #expect(tree.nodes[0].allocated == 32); #expect(tree.nodes[0].files == 2)
            #expect(tree.hardLinkAliases == 1)
            for path in ["/fixture/a", "/fixture/a/b", "/fixture/a/b/file", "/fixture/z"] {
                #expect(tree.nodes.first { $0.url?.path == path }?.logical == 7)
            }
            #expect(tree.nodes.first { $0.url?.path == "/fixture/z/alias" }?.files == 0)
        }
        var rootScan = DiskScan(); rootScan.entries = [entry("/file", 2), entry("/", 1, directory: true)]
        #expect(UsageTree(rootScan).nodes[0].logical == 7)
        #expect(UsageTree(DiskScan()).nodes.count == 1)
    }
    @Test func keepRulesAndCloneFamiliesAreDeterministic() {
        func file(_ path: String, date: Double, inode: UInt64, clone: UInt64? = nil) -> DuplicateFile {
            DuplicateFile(
                entry: DiskEntry(
                    url: URL(fileURLWithPath: path), identity: DiskIdentity(device: 1, inode: inode), directory: false, size: 10, allocated: 4096,
                    modified: Date(timeIntervalSince1970: date)), cloneID: clone)
        }
        let files = [
            file("/keep/long-name", date: 30, inode: 1, clone: 99), file("/x", date: 10, inode: 2, clone: 99), file("/other/f", date: 20, inode: 3),
        ]
        let group = DuplicateGroup(digest: "x", files: files)
        #expect(DuplicateKeepRule.newest.keeper(in: group)?.path == "/keep/long-name")
        #expect(DuplicateKeepRule.oldest.keeper(in: group)?.path == "/x")
        #expect(DuplicateKeepRule.shortestPath.keeper(in: group)?.path == "/x")
        #expect(DuplicateKeepRule.inFolder.keeper(in: group, preferredFolder: URL(fileURLWithPath: "/keep"))?.path == "/keep/long-name")
        #expect(group.isClone(files[0])); #expect(!group.isClone(files[2])); #expect(group.logicalSavings == 20)
    }
    @Test func treemapPreservesAreaAndBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 900, height: 300)
        let tiles = UsageTreemap.layout([(1, 300), (2, 100), (3, 600), (4, 0)], in: bounds)
        #expect(tiles.count == 3)
        #expect(abs(tiles.reduce(0.0) { $0 + $1.rect.width * $1.rect.height } - bounds.width * bounds.height) < 0.001)
        for tile in tiles { #expect(bounds.contains(tile.rect)) }
        for i in tiles.indices { for j in tiles.indices where j > i { #expect(tiles[i].rect.intersection(tiles[j].rect).isEmpty) } }
        #expect(UsageTreemap.layout([], in: bounds).isEmpty)
    }
}
