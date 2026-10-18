import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

struct FileJobPerformanceTests {
    @Test func aSameVolumeRenameDoesNotVisitTheTreeAndStillUndoes() throws {
        let s = try Scratch()
        let source = try s.folder("src/folder")
        for i in 0..<50 { try s.file("src/folder/sub/f\(i)", "bytes") }
        let destination = try s.folder("dst")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: destination)
        job.publishInterval = 0
        var preparing: [JobProgress] = []
        job.onProgress = { if $0.phase == .preparing { preparing.append($0) } }
        let undo = try #require(try job.run())
        #expect(preparing.count == 1)
        #expect(job.errors.isEmpty && job.results.map(\.path) == [s.path("dst/folder").path])
        #expect(s.read("dst/folder/sub/f49") == "bytes")
        try FileActions.undo(undo)
        #expect(s.read("src/folder/sub/f49") == "bytes" && !FileJob.itemExists(at: s.path("dst/folder")))
    }

    @Test func aConflictArrivingAfterPreparationRecoversInventory() throws {
        let s = try Scratch()
        let source = try s.file("src/file", "incoming")
        let destination = try s.folder("dst")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: destination)
        var arrived = false
        job.onProgress = { p in
            if p.phase == .transferring && !arrived {
                arrived = true
                try! s.file("dst/file", "keep")
            }
        }
        job.resolveConflict = { _ in .init(.skip) }
        _ = try job.run()
        #expect(s.read("src/file") == "incoming" && s.read("dst/file") == "keep")
        #expect(job.results.isEmpty && job.errors.isEmpty)
    }

    @Test func verificationCanStopWithinASingleLargeFile() throws {
        let s = try Scratch()
        let a = try s.file("a", size: 32 << 20), b = try s.file("b", size: 32 << 20)
        var checks = 0
        let result = CopyVerification.verify(
            a, b,
            cancelled: {
                checks += 1; return checks >= 5
            })
        #expect(checks >= 5 && checks < 12)
        #expect(result.mismatches.isEmpty)
        #expect(CopyVerification.digest(s.url) == nil)
    }
}
