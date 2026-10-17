import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

struct TransferStatusTests {
    @Test func rateAndTimeLeft() {
        var r = TransferRate()
        r.add(bytes: 0, at: 0)
        r.add(bytes: 10_000_000, at: 1)
        #expect(r.bytesPerSecond == 10_000_000)
        r.add(bytes: 10_000_100, at: 1.1)  // too soon: ignored
        #expect(r.bytesPerSecond == 10_000_000)
        r.add(bytes: 10_000_000, at: 3)  // two seconds without progress (paused) pull it down
        #expect(r.bytesPerSecond < 10_000_000 && r.bytesPerSecond > 0)
        r.reset()
        #expect(r.bytesPerSecond == 0)
        #expect(TransferRate.leftText(3) == "A few seconds left")
        #expect(TransferRate.leftText(42) == "About 40 seconds left")
        #expect(TransferRate.leftText(70) == "About 1 minute left")
        #expect(TransferRate.leftText(600) == "About 10 minutes left")
        #expect(TransferRate.leftText(3600) == "About 60 minutes left")
        #expect(TransferRate.leftText(5400) == "About 1 hour 30 minutes left")
    }

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
