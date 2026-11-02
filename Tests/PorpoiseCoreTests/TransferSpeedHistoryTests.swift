import Foundation
import PorpoiseCore
import Testing

struct TransferSpeedHistoryTests {
    @Test func graphTimesIncludePreparationBeforeFirstByteProgress() {
        var history = TransferSpeedHistory()
        history.begin(at: 10)
        history.add(bytes: 0, at: 15)
        history.add(bytes: 100, at: 16)
        #expect(history.samples.first?.elapsed == 6)
    }

    @Test func frequentCallbacksProduceBoundedHalfSecondSamples() throws {
        var history = TransferSpeedHistory()
        for tick in 0...2000 { history.add(bytes: Int64(tick * 100), at: Double(tick) / 10) }
        #expect(history.samples.count <= TransferSpeedHistory.capacity)
        #expect(history.samples.allSatisfy { abs($0.bytesPerSecond - 1000) < 0.001 })
        let first = try #require(history.samples.first), last = try #require(history.samples.last)
        #expect(last.elapsed == 200 && first.elapsed == 0.5)
    }

    @Test func historicalThinningKeepsElapsedSpanAndPauseBoundaries() throws {
        var history = TransferSpeedHistory()
        for tick in 0...200 { history.add(bytes: Int64(tick * 100), at: Double(tick)) }
        history.interrupt()
        for tick in 300...800 { history.add(bytes: Int64((tick - 100) * 100), at: Double(tick)) }
        let first = try #require(history.samples.first), last = try #require(history.samples.last)
        #expect(first.elapsed == 1 && last.elapsed == 800)
        #expect(history.samples.count <= TransferSpeedHistory.capacity)
        #expect(history.samples.contains { $0.segment == 0 } && history.samples.contains { $0.segment == 1 })
        #expect(!history.samples.contains { $0.elapsed > 200 && $0.elapsed < 301 })
        #expect(history.samples.allSatisfy { $0.bytesPerSecond == 100 })
    }

    @Test func pauseAndCounterResetDoNotIncludeWaitingOrNegativeSpeed() throws {
        var history = TransferSpeedHistory()
        history.add(bytes: 0, at: 0)
        history.add(bytes: 1000, at: 1)
        history.interrupt()
        history.add(bytes: 1000, at: 100)
        history.add(bytes: 2000, at: 101)
        #expect(history.samples.map(\.bytesPerSecond) == [1000, 1000])
        #expect(history.samples.map(\.segment) == [0, 1])
        history.add(bytes: 0, at: 102)
        history.add(bytes: 500, at: 103)
        #expect(history.samples.last?.bytesPerSecond == 500)
        #expect(history.samples.last?.segment == 2)
        let samples = history.samples
        history.add(bytes: 900, at: .nan)
        history.add(bytes: 900, at: .infinity)
        #expect(history.samples == samples)
    }
}
