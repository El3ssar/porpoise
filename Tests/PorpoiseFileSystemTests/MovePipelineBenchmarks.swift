import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

/// Opt-in end-to-end scratch-volume measurement; fixture/image creation is outside the clock.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PORPOISE_MOVE_BENCHMARK"] == "1"))
struct MovePipelineBenchmarks {
    @Test func nestedCrossVolumeMove() throws {
        let scratch = try Scratch("move-benchmark")
        let disk = try DiskImage(name: "PorpoiseMoveBench", megabytes: 1024, in: scratch)
        let chunk = Data(repeating: 0x5a, count: 1 << 20)
        for trial in 0..<3 {
            let source = try scratch.folder("source\(trial)")
            for index in 0..<16 {
                let file = try scratch.file("source\(trial)/a/b/c/d/file\(index)")
                let handle = try FileHandle(forWritingTo: file)
                for _ in 0..<32 { try handle.write(contentsOf: chunk) }
                try handle.close()
            }
            let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
            job.allowsClone = false
            let start = ProcessInfo.processInfo.systemUptime
            _ = try job.run()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            #expect(job.errors.isEmpty && job.denied.isEmpty)
            #expect(!FileJob.itemExists(at: source))
            print("W238_MOVE trial=\(trial) bytes=536870912 files=16 depth=5 seconds=\(elapsed)")
            try FileManager.default.removeItem(at: disk.volume.appendingPathComponent(source.lastPathComponent))
        }
    }
}
