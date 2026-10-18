import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite(.serialized) struct FileJobTests {
    private let scratch: Scratch

    init() throws { scratch = try Scratch("FileJob") }

    @Test func copyWithConflictRenameAndUndo() throws {
        let root = scratch.url
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: src.appendingPathComponent("a.bin"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("a.bin"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("a.bin")], destinationFolder: dst)
        var asked = 0
        job.resolveConflict = { info in
            asked += 1; return ConflictAnswer(.rename(info.suggestedName))
        }
        var last: JobProgress?
        job.onProgress = { last = $0 }
        let undo = try job.run()
        #expect(asked == 1)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a (1).bin").path))
        #expect(last?.doneBytes == 300_000)
        let u = try #require(undo)
        _ = try FileActions.undo(u)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("a (1).bin").path))
    }

    @Test func renameSuggestionSkipsNamesTakenInAnotherCase() throws {
        #expect(FileFormat.suggestedName(for: "Report.txt", existing: ["Report.txt", "report (1).txt"]) == "Report (2).txt")
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt", "A Copy.txt"]) == "a copy 2.txt")
        // On a case-insensitive volume "Report (1).txt" exists as "report (1).txt": suggested again and again,
        // the conflict never went away (an Apply to All rename looped forever).
        let root = scratch.url
        let src = root.appendingPathComponent("case-src"), dst = root.appendingPathComponent("case-dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        for (folder, name) in [(src, "Report.txt"), (dst, "Report.txt"), (dst, "report (1).txt")] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        try #require(FileJob.itemExists(at: dst.appendingPathComponent("Report (1).txt")), "needs a case-insensitive volume")
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("Report.txt")], destinationFolder: dst)
        var asked = 0
        job.resolveConflict = { info in
            asked += 1
            return asked > 3 ? ConflictAnswer(.cancel) : ConflictAnswer(.rename(info.suggestedName))
        }
        _ = try job.run()
        #expect(asked == 1)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Report (2).txt").path))
    }

    @Test func moveAndUndoMove() throws {
        let root = scratch.url
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let job = FileJob(kind: .move, sources: [a.appendingPathComponent("inner")], destinationFolder: b)
        let maybeUndo = try job.run()
        let undo = try #require(maybeUndo)
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("inner").path))
        let maybeRedo = try FileActions.undo(undo)
        let redo = try #require(maybeRedo)
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("inner").path))
        _ = try FileActions.undo(redo)
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("inner").path))
    }

    @Test func refusesCopyIntoItself() throws {
        let root = scratch.url
        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let job = FileJob(kind: .copy, sources: [a], destinationFolder: a.appendingPathComponent("sub"))
        _ = try job.run()
        #expect(job.errors.count == 1)
    }

    @Test func pasteIntoSameFolderMakesCopy() throws {
        let root = scratch.url
        try Data("x".utf8).write(to: root.appendingPathComponent("n.txt"))
        let job = FileJob(kind: .copy, sources: [root.appendingPathComponent("n.txt")], destinationFolder: root)
        _ = try job.run()
        #expect(job.results.map(\.lastPathComponent) == ["n copy.txt"])
    }

    @Test func mergeFolders() throws {
        let root = scratch.url
        let s = root.appendingPathComponent("s/f"), d = root.appendingPathComponent("d/f")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: s.appendingPathComponent("one"))
        try Data("2".utf8).write(to: d.appendingPathComponent("two"))
        let job = FileJob(kind: .copy, sources: [s], destinationFolder: root.appendingPathComponent("d"))
        job.resolveConflict = { _ in ConflictAnswer(.writeInto) }
        _ = try job.run()
        let names = try FileManager.default.contentsOfDirectory(atPath: d.path).sorted()
        #expect(names == ["one", "two"])
    }

    @Test func validateNames() throws {
        let root = scratch.url
        try FileManager.default.createDirectory(at: root.appendingPathComponent("x"), withIntermediateDirectories: true)
        #expect(FileActions.validateName("x", in: root, allowSlash: true)?.isError == true)
        #expect(FileActions.validateName(".h", in: root, allowSlash: true)?.isError == false)
        #expect(FileActions.validateName("ok", in: root, allowSlash: true) == nil)
    }

    @Test func permissionDeniedIsReportedSeparately() throws {
        let root = scratch.url
        let ro = root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ro.appendingPathComponent("f"))
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        let job = FileJob(kind: .delete, sources: [ro.appendingPathComponent("f")])
        _ = try job.run()
        #expect(job.denied == [ro.appendingPathComponent("f")])
        #expect(job.errors.isEmpty)
    }
}
