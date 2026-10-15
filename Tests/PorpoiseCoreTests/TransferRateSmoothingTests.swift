import Foundation
import Testing

@testable import PorpoiseCore

struct TransferRateSmoothingTests {
    @Test func displayBucketsUseFinderStyleRounding() {
        #expect(TransferRate.leftText(9) == "A few seconds left")
        #expect(TransferRate.leftText(34) == "About 35 seconds left")
        #expect(TransferRate.leftText(61) == "About 1 minute left")
        #expect(TransferRate.leftText(248) == "About 4 minutes left")
        #expect(TransferRate.leftText(7_850) == "About 2 hours 10 minutes left")
    }

    @Test func displayWaitsForEligibilityAndTwoSecondsOfStableBucket() {
        var rate = TransferRate()
        rate.add(bytes: 0, at: 0, totalBytes: 100_000)
        for second in 1...3 {
            rate.add(bytes: Int64(second * 1_000), at: Double(second), totalBytes: 100_000)
            #expect(rate.timeLeftText == "Estimating time…")
        }
        rate.add(bytes: 4_000, at: 4, totalBytes: 100_000)
        #expect(rate.timeLeftText == "About 2 minutes left")
        #expect(rate.hasSpeedEstimate)
        #expect(rate.speedText == 1.0.formatted(.number.precision(.fractionLength(1))) + " KB/s")
        rate.reset()
        #expect(!rate.hasSpeedEstimate && rate.timeLeftText == "Estimating time…")
    }

    @Test func stallAndManySmallFilesUseIndependentItemRate() {
        var rate = TransferRate()
        rate.add(bytes: 0, at: 0, totalBytes: 10_000, items: 0, totalItems: 1_000)
        for second in 1...5 { rate.add(bytes: Int64(second * 1_000), at: Double(second), totalBytes: 10_000, items: second, totalItems: 1_000) }
        #expect(rate.timeLeftText == "About 17 minutes left")
        for second in 6...10 { rate.add(bytes: 5_000, at: Double(second), totalBytes: 10_000, items: 5, totalItems: 1_000) }
        #expect(rate.timeLeftText == "Stalled")
        rate.add(bytes: 6_000, at: 11, totalBytes: 10_000, items: 6, totalItems: 1_000)
        #expect(rate.timeLeftText != "Stalled")
    }

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
