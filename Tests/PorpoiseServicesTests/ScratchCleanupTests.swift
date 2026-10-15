import Darwin
import Foundation
import PorpoiseTestSupport
import Testing

struct ScratchCleanupTests {
    @Test func ordinaryFixturesAndOutsidePointingLinksAreRemovedPhysically() throws {
        let outside = try Scratch()
        let precious = try outside.file("keep.txt", "keep")
        var scratch: Scratch? = try Scratch()
        let root = try #require(scratch?.url)
        try scratch?.file("nested/file.txt", "remove")
        try scratch?.symlink("link", to: outside.url.path)
        scratch = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }
    @Test func lockedItemsInReadOnlyFoldersStillRecoverAndDisappear() throws {
        var scratch: Scratch? = try Scratch()
        let root = try #require(scratch?.url)
        let created = try scratch?.file("readonly/locked.txt", "remove")
        let file = try #require(created)
        try #require(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        try #require(chmod(file.deletingLastPathComponent().path, 0o555) == 0)
        scratch = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func previouslyRemovedFixtureNeedsNoRecovery() throws {
        var scratch: Scratch? = try Scratch()
        let root = try #require(scratch?.url)
        try FileManager.default.removeItem(at: root)
        scratch = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
