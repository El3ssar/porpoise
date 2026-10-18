import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

// Process-wide malloc measurements share the existing serialized suite. A separate suite would
// run alongside the index memory measurement and charge its allocations to this file-job test.
extension MemoryBudgetTests {
    @Test func streamingReadsReleaseChunksBeforeTheWorkItemEnds() async throws {
        let s = try Scratch()
        let a = try s.file("a", size: 64 << 20), b = try s.file("b", size: 64 << 20)
        func allocated() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }
        let growth: Int = await withCheckedContinuation { done in
            Thread {
                autoreleasepool {
                    let before = allocated()
                    let result = CopyVerification.verify(a, b)
                    #expect(result.ok && result.bytes == 64 << 20)
                    do {
                        #expect(try FileComparison.firstDifference(a, b) == nil)
                        #expect(try FileChecksums.digest(a) == FileChecksums.digest(b))
                    } catch { Issue.record(error) }
                    // Sample inside the outer pool, like one long GCD job. A per-file or per-job pool
                    // alone would still retain all buffers from a single large file until this point.
                    done.resume(returning: allocated() - before)
                }
            }.start()
        }
        #expect(growth < 24 << 20, "Streaming reads retained \(growth >> 20) MiB before the work item ended")
    }
}
