import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct SyncPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNC_BENCHMARK"] == "1"))
    func localHundredThousandWarm() throws {
        let scratch = try Scratch()
        // Empty files isolate directory/metadata cost; SHA-256 content scanning is deliberately a separate mode.
        for index in 0..<100_000 { FileManager.default.createFile(atPath: scratch.path("file-\(index)").path, contents: Data()) }
        _ = try SyncScanner.scan(scratch.url)
        let start = Date()
        let result = try SyncScanner.compare(scratch.url, scratch.url).comparison
        print("SYNC_PERF local concurrent scans + compare 100000 per side: \(Date().timeIntervalSince(start)) seconds")
        #expect(result.rows.count == 100_000)
        #expect(result.rows.allSatisfy { $0.status == .same })
    }
}
