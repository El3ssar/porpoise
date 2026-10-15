import Foundation
import Testing

@testable import PorpoiseCore

struct TransferRateSmoothingTests {
    @Test func smoothingDoesNotDependOnCallbackFrequency() {
        func start() -> TransferRate {
            var rate = TransferRate()
            rate.add(bytes: 0, at: 0)
            rate.add(bytes: 1_000, at: 1)
            return rate
        }
        var frequent = start(), sparse = start()
        for step in 1...16 { frequent.add(bytes: 1_000, at: 1 + Double(step) / 4) }
        sparse.add(bytes: 1_000, at: 5)
        #expect(abs(frequent.bytesPerSecond - sparse.bytesPerSecond) < 0.0001)
        #expect(abs(sparse.bytesPerSecond - 1_000 * exp(-4.0 / 3)) < 0.0001)
    }

    @Test func aStallCannotMakeEtaJumpByMinutes() throws {
        var rate = TransferRate()
        rate.add(bytes: 0, at: 0, totalBytes: 1_000_000)
        rate.add(bytes: 10_000, at: 1, totalBytes: 1_000_000)
        let before = try #require(rate.secondsLeft(990_000))
        rate.add(bytes: 10_000, at: 2, totalBytes: 1_000_000)
        let after = try #require(rate.secondsLeft(990_000))
        #expect(after <= before + 3 && after >= before - 3)
        rate.add(bytes: 1_000_000, at: 3, totalBytes: 1_000_000)
        #expect(rate.secondsLeft(0) == 0)
        rate.reset()
        #expect(rate.secondsLeft(100) == nil)
    }

    @Test func invalidAndResetCountersRemainFinite() {
        var rate = TransferRate()
        rate.add(bytes: 100, at: .nan)
        rate.add(bytes: 100, at: 1)
        rate.add(bytes: 50, at: 2)
        #expect(rate.bytesPerSecond == 0)
        rate.add(bytes: 150, at: 3)
        #expect(rate.bytesPerSecond == 100)
        #expect(TransferRate.leftText(.infinity) == "Estimating time left…")
    }
}
