import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

/// Verification is a proof that a copy is complete (recovery removes originals on it): a folder or link it can't read,
/// or a scan cut short, never counts as identical.
@Suite struct VerificationFailureSafetyTests {
    struct ReadFailure: Error {}

    /// Different trees whose folders can't be listed: injected, so it holds whatever the host's privileges.
    @Test func unreadableFoldersAreNeverEqual() throws {
        let s = try Scratch("verify-unreadable")
        try s.file("a/only-in-original.txt", "a")
        try s.file("b/only-in-copy.txt", "different")
        let a = s.path("a"), b = s.path("b")
        var reader = CopyVerification.Reader()
        reader.list = { _ in throw ReadFailure() }
        let both = CopyVerification.verify(a, b, reader: reader)
        #expect(!both.ok && both.files == 0)
        #expect(both.mismatches == [.init(path: "", reason: "the original could not be read")])

        // Only the copy unreadable, or only a folder inside it.
        reader.list = { path in
            if path == b.path { throw ReadFailure() }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        #expect(CopyVerification.verify(a, b, reader: reader).mismatches == [.init(path: "", reason: "the copy could not be read")])
        try s.file("a/sub/x.txt", "x")
        try FileManager.default.removeItem(at: b)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(CopyVerification.verify(a, b).ok)
        reader.list = { path in
            if path.hasSuffix("/a/sub") { throw ReadFailure() }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        let nested = CopyVerification.verify(a, b, reader: reader)
        #expect(!nested.ok && nested.mismatches.map(\.path) == ["sub"])
        #expect(nested.summary.contains("sub: the original could not be read"))
    }

    /// An unreadable original against an empty copy: the case that lets a move remove what it never copied.
    @Test func anUnreadableOriginalDoesNotMatchAnEmptyCopy() throws {
        let s = try Scratch("verify-empty")
        try s.file("a/data.txt", "data")
        let empty = try s.folder("b")
        var reader = CopyVerification.Reader()
        reader.list = { path in
            if path == s.path("a").path { throw ReadFailure() }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        #expect(!CopyVerification.verify(s.path("a"), empty, reader: reader).ok)
    }

    /// The real thing, where permissions apply (not as root, which reads anything).
    @Test(.enabled(if: geteuid() != 0)) func aFolderWithoutReadPermissionFailsVerification() throws {
        let s = try Scratch("verify-chmod")
        try s.file("a/locked/secret.txt", "one")
        try s.file("b/locked/other.txt", "two")
        let locked = s.path("a/locked"), lockedCopy = s.path("b/locked")
        chmod(locked.path, 0)
        chmod(lockedCopy.path, 0)
        defer {
            chmod(locked.path, 0o755)
            chmod(lockedCopy.path, 0o755)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil)
        let r = CopyVerification.verify(s.path("a"), s.path("b"))
        #expect(!r.ok && r.mismatches == [.init(path: "locked", reason: "the original could not be read")])
    }

    @Test func linksThatCannotBeReadAreNotEqual() throws {
        let s = try Scratch("verify-links")
        try s.symlink("a", to: "one")
        try s.symlink("b", to: "two")
        var reader = CopyVerification.Reader()
        reader.link = { _ in throw ReadFailure() }
        let r = CopyVerification.verify(s.path("a"), s.path("b"), reader: reader)
        #expect(r.mismatches == [.init(path: "", reason: "the link could not be read")])
        // One side readable is no better.
        reader.link = { path in
            if path.hasSuffix("/b") { throw ReadFailure() }
            return try FileManager.default.destinationOfSymbolicLink(atPath: path)
        }
        #expect(CopyVerification.verify(s.path("a"), s.path("a"), reader: reader).ok)
        #expect(!CopyVerification.verify(s.path("a"), s.path("b"), reader: reader).ok)
    }

    @Test func aCancelledScanIsIncompleteNotIdentical() throws {
        let s = try Scratch("verify-cancel")
        try s.file("a/1.txt", "1")
        try s.file("a/2.txt", "2")
        try s.file("b/1.txt", "1")
        try s.file("b/2.txt", "different")
        // Cancelled at once: nothing compared.
        let none = CopyVerification.verify(s.path("a"), s.path("b"), cancelled: { true })
        #expect(none.incomplete && !none.ok && none.mismatches.isEmpty)
        #expect(none.summary.hasPrefix("Verification stopped after 0 files") && none.summary.hasSuffix("not everything was compared."))
        // Cancelled partway, before the file that differs.
        var asked = 0
        let partway = CopyVerification.verify(
            s.path("a"), s.path("b"),
            cancelled: {
                asked += 1; return asked > 4
            })
        #expect(partway.incomplete && !partway.ok)
    }

    @Test func equalFilesAndFoldersStillVerify() throws {
        let s = try Scratch("verify-equal")
        let a = try s.randomFile("a.bin", size: 3 << 20, seed: 9)
        let b = s.path("b.bin")
        try FileManager.default.copyItem(at: a, to: b)
        let r = CopyVerification.verify(a, b)
        #expect(r.ok && !r.incomplete && r.files == 1 && r.bytes == 3 << 20)
        try s.file("d/x/y.txt", "y")
        try s.symlink("d/link", to: "x/y.txt")
        try FileManager.default.copyItem(at: s.path("d"), to: s.path("e"))
        #expect(CopyVerification.verify(s.path("d"), s.path("e")).ok)
    }
}
