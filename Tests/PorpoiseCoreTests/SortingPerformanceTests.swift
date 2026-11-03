import Foundation
import os
import Testing

@testable import PorpoiseCore

/// Diagnostic only: no timing threshold and no filesystem reads. Run in an optimized build with
/// PORPOISE_SORTING_BENCHMARK=1; the ordinary API is the pre-cancellation control workload.
@Suite struct SortingPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_SORTING_BENCHMARK"] == "1"))
    func largeSortCancellation() throws {
        var seed: UInt64 = 713
        var values = Array(0..<100_000)
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.swapAt(index, Int(seed % UInt64(index + 1)))
        }
        let items = values.map {
            FileItem(url: URL(fileURLWithPath: "/tmp/porpoise-sort-probe/file\($0).txt"), name: "file\($0).txt", isDirectory: false)
        }
        for cooperative in [false, true] {
            for stop in [false, true] {
                let cancellation = DiskCancellation()
                let cancelledAt = OSAllocatedUnfairLock(initialState: UInt64(0))
                if stop {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(10)) {
                        cancelledAt.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
                        cancellation.cancel()
                    }
                }
                let start = DispatchTime.now().uptimeNanoseconds
                let sorted = cooperative
                    ? ItemSorter.sort(items, props: ViewProperties(), cancelled: { cancellation.isCancelled })
                    : ItemSorter.sort(items, props: ViewProperties())
                let end = DispatchTime.now().uptimeNanoseconds
                if cooperative && stop {
                    #expect(sorted == nil)
                } else {
                    #expect(sorted?.first?.name == "file0.txt" && sorted?.last?.name == "file99999.txt")
                }
                var record: [String: Any] = ["cooperative": cooperative, "cancelled": stop, "count": items.count,
                                              "total_ms": Double(end - start) / 1e6]
                if stop {
                    try #require(cancellation.isCancelled)
                    record["after_cancel_ms"] = Double(end - cancelledAt.withLock { $0 }) / 1e6
                }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print("SORTING_BENCHMARK " + String(decoding: data, as: UTF8.self))
            }
        }
    }
}
