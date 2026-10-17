import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct DiskUtilityServiceTests {
    @Test func bulkInventoryMatchesStatAndCountsPhysicalHardLinks() throws {
        let s = try Scratch()
        try s.file("root/a.txt", "hello")
        try s.file("root/nested/café.txt", "world")
        try FileManager.default.linkItem(at: s.path("root/a.txt"), to: s.path("root/alias.txt"))
        try s.symlink("root/loop", to: s.path("root").path)
        let scan = PhysicalTreeScanner.scan([s.path("root"), s.path("root/nested")])
        #expect(scan.errors.isEmpty)
        #expect(scan.entries.count == 6)
        for file in scan.entries where !file.symlink {
            let actual = try PhysicalTreeScanner.entry(file.url)
            #expect(file.identity == actual.identity)
            #expect(file.directory == actual.directory)
            if !file.directory { #expect(file.size == actual.size); #expect(file.allocated == actual.allocated) }
            #expect(abs(file.modified.timeIntervalSince(actual.modified)) < 0.000001)
        }
        let tree = UsageTree(scan)
        #expect(tree.nodes[0].logical == 10); #expect(tree.nodes[0].files == 2); #expect(tree.hardLinkAliases == 1)
        let shallow = PhysicalTreeScanner.scan([s.path("root")], maxDepth: 1)
        #expect(!shallow.entries.contains { $0.url.lastPathComponent == "café.txt" })
    }
    @Test func manifestVerificationReportsMismatchMissingAndUnsafePaths() throws {
        let s = try Scratch(); try s.file("a.txt", "abc"); try s.file("other", "outside")
        let digest = try FileChecksums.digest(s.path("a.txt"))
        let entries = [
            ChecksumEntry(path: "a.txt", algorithm: .sha256, digest: digest), ChecksumEntry(path: "missing", algorithm: .sha256, digest: digest),
            ChecksumEntry(path: "../other", algorithm: .sha256, digest: digest),
        ]
        let results = try FileChecksums.verify(entries, below: s.url)
        #expect(results.map(\.matches) == [true, false, false]); #expect(results[1].error != nil); #expect(results[2].error != nil)
        try s.file("a.txt", "changed")
        let mismatch = try FileChecksums.verify([entries[0]], below: s.url)
        #expect(!mismatch[0].matches && mismatch[0].actual != nil && mismatch[0].error == nil)
        try s.file("checks.sha256", ChecksumManifest.export(entries))
        #expect(try FileChecksums.loadManifest(s.path("checks.sha256")) == entries)
    }

    @Test func manifestVerificationHandlesOddRealNamesAndRejectsSymlinkEscapes() throws {
        let s = try Scratch(); try s.file("inside/café\nname", "abc"); try s.file("outside", "abc")
        let digest = try FileChecksums.digest(s.path("outside"))
        try s.symlink("inside/escape", to: s.path("outside").path)
        let entries = [
            ChecksumEntry(path: "café\nname", algorithm: .sha256, digest: digest), ChecksumEntry(path: "escape", algorithm: .sha256, digest: digest),
        ]
        let parsed = try ChecksumManifest.parse(ChecksumManifest.export(entries))
        let result = try FileChecksums.verify(parsed, below: s.path("inside"))
        #expect(result.map(\.matches) == [true, false]); #expect(result[1].error != nil)
    }

    @Test func hashCancellationAndConcurrentChangesAreRejected() throws {
        let s = try Scratch(); try s.file("large", "", size: 2 * 1024 * 1024)
        let cancel = DiskCancellation(); cancel.cancel()
        #expect(throws: CancellationError.self) { try FileChecksums.digest(s.path("large"), cancellation: cancel) }
        let original = try PhysicalTreeScanner.entry(s.path("large"))
        try s.file("large", "different")
        #expect(throws: FileChecksumError.self) { try FileChecksums.digest(s.path("large"), expected: original) }
        try s.file("large", "", size: 2 * 1024 * 1024)
        var changed = false
        #expect(throws: FileChecksumError.self) {
            try FileChecksums.digest(s.path("large")) { _ in
                if !changed { changed = true; try? Data("replaced".utf8).write(to: s.path("large")) }
            }
        }
        try s.symlink("link", to: s.path("large").path)
        #expect(throws: (any Error).self) { try FileChecksums.digest(s.path("link")) }
        #expect(mkfifo(s.path("fifo").path, 0o600) == 0)
        #expect(throws: FileChecksumError.self) { try FileChecksums.digest(s.path("fifo")) }
        let scan = PhysicalTreeScanner.scan([s.url], cancellation: cancel)
        #expect(scan.cancelled && scan.entries.isEmpty)
    }
    @Test func duplicatesStagePartialThenFullAndIgnoreEmptyLinks() throws {
        let s = try Scratch()
        let a = try s.file("a", "same"), b = try s.file("b", "same")
        try s.file("different-size", "unique")
        try s.file("empty1"); try s.file("empty2")
        try FileManager.default.linkItem(at: a, to: s.path("hard-link")); try s.symlink("symlink", to: a.path)
        let result = try DuplicateFinder.find(in: PhysicalTreeScanner.scan([s.url]))
        #expect(result.groups.count == 1); #expect(result.groups[0].files.map { $0.entry.url.lastPathComponent }.sorted() == ["a", "b"])
        #expect(result.hardLinksIgnored == 1); #expect(result.fullHashes == 2)
        #expect(try DuplicateFinder.validate(result.groups, marked: [b]).map(\.lastPathComponent) == ["b"])
        #expect(throws: FileChecksumError.self) { try DuplicateFinder.validate(result.groups, marked: [a, b]) }
        try s.file("b", "now changed")
        #expect(throws: FileChecksumError.self) { try DuplicateFinder.validate(result.groups, marked: [b]) }
    }
    @Test func equalPartialHashesStillRequireMatchingMiddleBytes() throws {
        let s = try Scratch()
        let prefix = String(repeating: "p", count: 64 * 1024), suffix = String(repeating: "s", count: 64 * 1024)
        try s.file("a", prefix + "aaaa" + suffix); try s.file("b", prefix + "bbbb" + suffix)
        #expect(try FileChecksums.digest(s.path("a"), partial: true) == FileChecksums.digest(s.path("b"), partial: true))
        let result = try DuplicateFinder.find(in: PhysicalTreeScanner.scan([s.url]))
        #expect(result.groups.isEmpty); #expect(result.partialHashes == 2); #expect(result.fullHashes == 2)
    }

    @Test func growingFilesAreBoundedByTheirInitialLength() throws {
        let s = try Scratch(); try s.file("growing", "", size: 512 * 1024)
        var grew = false, maxRead: Int64 = 0
        #expect(throws: FileChecksumError.self) {
            try FileChecksums.digest(s.path("growing")) { bytes in
                maxRead = max(maxRead, bytes)
                if !grew {
                    grew = true
                    if let handle = try? FileHandle(forWritingTo: s.path("growing")) {
                        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(repeating: 1, count: 512 * 1024)); try? handle.close()
                    }
                }
            }
        }
        #expect(maxRead == 512 * 1024)
    }

    @Test func APFSClonesAreReportedWithoutTreatingThemAsHardLinks() throws {
        let s = try Scratch(); let original = try s.file("original", String(repeating: "clone data ", count: 20000))
        let clone = s.path("clone")
        try #require(clonefile(original.path, clone.path, 0) == 0, "APFS clonefile must work on the test volume")
        let result = try DuplicateFinder.find(in: PhysicalTreeScanner.scan([s.url]))
        let group = try #require(result.groups.first)
        #expect(group.files.count == 2); #expect(result.hardLinksIgnored == 0)
        let ids = group.files.map(\.cloneID)
        print("APFS clone family ids: \(ids)")
        if ids.allSatisfy({ $0 != nil }) {
            #expect(ids[0] == ids[1]); #expect(group.files.allSatisfy { group.isClone($0) })
        } else {
            #expect(group.files.allSatisfy { !group.isClone($0) })
            print("Filesystem supports clonefile but does not expose clone-family tracking")
        }
    }
    @Test func unreadableDirectoriesAreExplicitAndCacheCanBeInvalidated() throws {
        let s = try Scratch(); try s.file("root/readable/file", "hello"); try s.file("root/denied/file", "secret")
        let denied = s.path("root/denied").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied) }
        let scan = PhysicalTreeScanner.scan([s.path("root")])
        #expect(scan.errors.count == 1); #expect(UsageTree(scan).nodes[0].logical == 5)
        let cache = FolderUsageCache()
        #expect(cache.size(s.path("root/readable"), depth: 10) == 5)
        try s.file("root/readable/file", "changed content")
        cache.invalidate(below: s.path("root"))
        #expect(cache.size(s.path("root/readable"), depth: 10) == 15)
    }
    @Test func selectedMountedVolumesAreScannedButNotCrossedImplicitly() throws {
        let s = try Scratch(); let image = try DiskImage(in: s)
        let file = image.volume.appendingPathComponent("on-volume.txt")
        try Data("mounted".utf8).write(to: file)
        let defaultScan = PhysicalTreeScanner.scan([s.url])
        #expect(!defaultScan.entries.contains { $0.url.lastPathComponent == "on-volume.txt" })
        let explicit = PhysicalTreeScanner.scan([image.volume])
        #expect(explicit.entries.contains { $0.url.lastPathComponent == "on-volume.txt" })
    }
}
