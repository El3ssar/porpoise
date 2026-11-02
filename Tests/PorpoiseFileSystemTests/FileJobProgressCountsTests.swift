import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

struct FileJobProgressCountsTests {
    @Test func skippedAndMergedFoldersCountProcessedWorkWithoutDoubleCounting() throws {
        for skipWholeFolder in [true, false] {
            let scratch = try Scratch()
            let source = try scratch.folder("source/nested/empty")
            try scratch.file("source/nested/a.txt", "new")
            try scratch.file("source/b.txt", "b")
            let destination = try scratch.folder("destination/source/nested")
            try scratch.file("destination/source/nested/a.txt", "old")
            let job = FileJob(
                kind: .copy, sources: [source.deletingLastPathComponent().deletingLastPathComponent()],
                destinationFolder: destination.deletingLastPathComponent().deletingLastPathComponent())
            job.resolveConflict = { info in .init(skipWholeFolder || !info.source.isDirectory ? .skip : .writeInto) }
            job.allowsClone = false
            var final: JobProgress?
            job.onProgress = { final = $0 }
            _ = try job.run()
            let progress = try #require(final)
            #expect(progress.countsAreComplete)
            #expect(progress.doneFiles == 2 && progress.totalFiles == 2)
            #expect(progress.doneFolders == 3 && progress.totalFolders == 3)
            #expect(progress.nonTransferredBytes == (skipWholeFolder ? 4 : 3))
            #expect(progress.transferredBytes == (skipWholeFolder ? 0 : 1))
            #expect(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
            #expect(
                FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("b.txt").path)
                    == !skipWholeFolder)
        }
    }

    @Test func recursiveCopyCountsFoldersSeparatelyFromFiles() throws {
        let scratch = try Scratch()
        let source = try scratch.folder("source/nested")
        try scratch.file("source/nested/a.txt", "a")
        try scratch.file("source/b.txt", "bb")
        let destination = try scratch.folder("destination")
        let job = FileJob(kind: .copy, sources: [source.deletingLastPathComponent()], destinationFolder: destination)
        var final: JobProgress?
        job.onProgress = { final = $0 }
        _ = try job.run()
        let progress = try #require(final)
        #expect(progress.countsAreComplete)
        #expect(progress.totalFiles == 2 && progress.doneFiles == 2)
        #expect(progress.totalFolders == 2 && progress.doneFolders == 2)
    }

    @Test func fastDirectoryMoveKeepsRecursiveCountsUnknown() throws {
        let scratch = try Scratch()
        let source = try scratch.folder("source/nested")
        try scratch.file("source/nested/a.txt", "a")
        let destination = try scratch.folder("destination")
        let job = FileJob(kind: .move, sources: [source.deletingLastPathComponent()], destinationFolder: destination)
        var final: JobProgress?
        job.onProgress = { final = $0 }
        _ = try job.run()
        let progress = try #require(final)
        #expect(!progress.countsAreComplete)
        #expect(progress.totalFiles == 0 && progress.doneFiles == 0)
        #expect(progress.totalFolders == 1 && progress.doneFolders == 1)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source/nested/a.txt").path))
    }
}
