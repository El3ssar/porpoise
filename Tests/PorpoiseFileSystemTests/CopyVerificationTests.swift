import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct CopyVerificationTests {
    @Test func verification() throws {
        let s = try Scratch("verify")
        try s.file("a/one.txt", "one")
        try s.file("a/sub/two.txt", "two")
        try s.symlink("a/link", to: "one.txt")
        let fm = FileManager.default
        try fm.copyItem(at: s.path("a"), to: s.path("b"))
        let same = CopyVerification.verify(s.path("a"), s.path("b"))
        #expect(same.ok && same.files == 2 && same.bytes == 6)
        #expect(same.summary.hasPrefix("Verified 2 files"))
        try "TWO".write(to: s.path("b/sub/two.txt"), atomically: true, encoding: .utf8)
        try "longer".write(to: s.path("b/one.txt"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: s.path("b/link"))
        try s.file("b/extra", "")
        let diff = CopyVerification.verify(s.path("a"), s.path("b"))
        #expect(
            diff.mismatches.map(\.path) == ["link", "extra", "one.txt", "sub/two.txt"])
        #expect(diff.mismatches.last?.reason == "different contents (SHA-256)")
        #expect(diff.summary.hasPrefix("Verification found 4 differences"))
        #expect(CopyVerification.verify(s.path("a/one.txt"), s.path("nowhere")).mismatches.first?.reason == "missing in the copy")
        #expect(CopyVerification.verify(s.path("a"), s.path("a/one.txt")).mismatches.first?.reason == "a different kind of item")
    }
}
