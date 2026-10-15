import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A scan blocks its caller until the folders are read. It must finish even when no other thread is free to help
/// (CI's 3-core runner: every test thread waiting on scans, nothing left to run their work).
@Suite struct ScannerStarvationTests {
    @Test func scansFinishWhenEveryWorkerThreadIsTaken() throws {
        let s = try Scratch()
        for d in 0..<4 {
            for f in 0..<5 { try s.file("root/d\(d)/f\(f)") }
        }
        let callers = 100  // more than the system gives a queue's work at once
        let group = DispatchGroup()
        let lock = NSLock()
        var counts: [Int] = []
        for _ in 0..<callers {
            group.enter()
            DispatchQueue.global().async {
                let n = PhysicalTreeScanner.scan([s.path("root")]).entries.count
                lock.withLock { counts.append(n) }
                group.leave()
            }
        }
        try #require(group.wait(timeout: .now() + 60) == .success, "scans never finished: \(lock.withLock { counts.count }) of \(callers)")
        #expect(counts == Array(repeating: 1 + 4 + 20, count: callers))
    }
}
