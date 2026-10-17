import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

struct FilePathTests {
    @Test func identitiesSurviveCreateDeleteAndRespectSymlinkEntries() throws {
        let s = try Scratch(), folder = try s.folder("real"), alias = s.path("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let missing = alias.appendingPathComponent("new/deep/file")
        let before = FilePath(canonical: missing)
        try s.file("real/new/deep/file", "x")
        #expect(FilePath(canonical: missing) == before)
        try FileManager.default.removeItem(at: s.path("real/new"))
        #expect(FilePath(canonical: missing) == before)
        #expect(FilePath(canonical: alias) == FilePath(canonical: folder))
        #expect(!FilePath.sameItem(alias, folder))
        #expect(FilePath(entry: folder).contains(before))
        #expect(!FilePath.contains(path: folder.path + "-sibling/file", in: folder.path))
        #expect(FilePath.contains(path: before.path, in: "/"))
        #expect(FilePath.existing(missing.path) == nil)
        let remote = URL(string: "sftp://host/private/tmp/opaque?scope=one")!
        #expect(FilePath.key(remote) == remote.absoluteString)
        let entries = [missing, alias, folder, remote]
        #expect(FilePath.keys(entries) == entries.map(FilePath.key))
    }
}
