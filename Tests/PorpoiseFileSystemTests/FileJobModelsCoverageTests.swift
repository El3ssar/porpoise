import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct FileJobModelsCoverageTests {
    @Test func aJobWithoutSourcesDoesNothing() throws {
        var names: [String] = []
        let job = FileJob(kind: .delete, sources: [])
        job.onProgress = { names.append($0.currentName) }
        #expect(try job.run() == nil)
        #expect(names.allSatisfy { $0.isEmpty } && !names.isEmpty)
        #expect(job.results.isEmpty && job.errors.isEmpty)
    }
    @Test func aVanishedSourceMeetingAConflictIsSkipped() throws {
        let s = try Scratch()
        let dest = try s.folder("dest")
        try s.file("dest/gone.txt", "keep")
        var asked = 0
        let job = FileJob(kind: .copy, sources: [s.path("gone.txt")], destinationFolder: dest)
        job.resolveConflict = { _ in
            asked += 1; return ConflictAnswer(.overwrite)
        }
        _ = try job.run()
        #expect(asked == 0)
        #expect(job.results.isEmpty && job.errors.isEmpty)
        #expect(s.read("dest/gone.txt") == "keep")
    }
    @Test func overwriteIfOlderForAllSkipsAVanishedSource() throws {
        let s = try Scratch()
        let dest = try s.folder("dest")
        try s.file("dest/a.txt", "old a"); try s.file("dest/b.txt", "old b")
        let old = Date().addingTimeInterval(-86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: s.path("dest/a.txt").path)
        let a = try s.file("a.txt", "new a")
        let job = FileJob(kind: .copy, sources: [a, s.path("b.txt")], destinationFolder: dest)
        var asked = 0
        job.resolveConflict = { _ in
            asked += 1; return ConflictAnswer(.overwriteIfOlder, applyToAll: true)
        }
        _ = try job.run()
        #expect(asked == 1)
        #expect(s.read("dest/a.txt") == "new a" && s.read("dest/b.txt") == "old b")
        #expect(job.errors.isEmpty)
    }
    @Test func conflictInAFolderThatCannotBeListed() throws {
        let s = try Scratch()
        let dest = try s.folder("dropbox")
        try s.file("dropbox/x.txt", "theirs")
        let src = try s.file("x.txt", "mine")
        chmod(dest.path, 0o300)
        defer { chmod(dest.path, 0o755) }
        var suggestion = ""
        let job = FileJob(kind: .copy, sources: [src], destinationFolder: dest)
        job.resolveConflict = { info in
            suggestion = info.suggestedName; return ConflictAnswer(.skip)
        }
        _ = try job.run()
        #expect(suggestion == "x (1).txt")
        chmod(dest.path, 0o755)
        #expect(s.read("dropbox/x.txt") == "theirs")
    }
    @Test func cancelInsideAMergeStopsTheJob() throws {
        let s = try Scratch()
        try s.file("src/box/a.txt", "new"); try s.file("src/box/b.txt", "new b")
        try s.file("dest/box/a.txt", "old")
        let job = FileJob(kind: .copy, sources: [s.path("src/box")], destinationFolder: s.path("dest"))
        var answers = [ConflictAnswer(.writeInto), ConflictAnswer(.cancel)]
        job.resolveConflict = { _ in answers.removeFirst() }
        _ = try job.run()
        #expect(job.isCancelled && answers.isEmpty)
        #expect(job.errors.isEmpty)
        #expect(s.read("dest/box/a.txt") == "old")
    }
}
