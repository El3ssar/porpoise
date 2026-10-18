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

}
