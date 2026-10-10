import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Data-safety behavior of FileJob and FileActions: conflicts, overwrite, merge, undo, permissions.
@Suite(.serialized) struct FileJobSafetyTests {
    let fm = FileManager.default
    /// One per test (Swift Testing makes a new suite value for each), removed with it.
    private let scratch: Scratch

    private var root: URL { scratch.url }

    init() throws { scratch = try Scratch("FileJobSafety") }

    /// `src` and `dst` subfolders of the test's scratch folder.
    private func sandbox() throws -> (src: URL, dst: URL) {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        return (src, dst)
    }

    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    private func exists(_ url: URL) -> Bool { FileJob.itemExists(at: url) }
    private func listing(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    // MARK: Overwrite

    @Test func overwriteReplacesFileWithoutLeftovers() throws {
        let (src, dst) = try sandbox()
        try write("new", src.appendingPathComponent("f"))
        try write("old", dst.appendingPathComponent("f"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(read(dst.appendingPathComponent("f")) == "new")
        #expect(listing(dst) == ["f"])   // no staging file left behind
        #expect(job.errors.isEmpty)
    }

    @Test func failedOverwriteKeepsTheDestination() throws {
        let (src, dst) = try sandbox()
        // A folder with an unreadable subfolder: the copy fails halfway.
        let s = src.appendingPathComponent("f"), locked = s.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try write("a", s.appendingPathComponent("a"))
        try write("b", locked.appendingPathComponent("b"))
        try write("old", dst.appendingPathComponent("f"))
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        let job = FileJob(kind: .copy, sources: [s], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(read(dst.appendingPathComponent("f")) == "old")
        #expect(listing(dst) == ["f"])   // the partial copy was removed
        #expect(job.denied == [s], "\(job.errors)")
        #expect(job.deniedTargets[s]?.path == dst.appendingPathComponent("f").path)
    }

    @Test func overwriteFileWithFolderAndBack() throws {
        let (src, dst) = try sandbox()
        try fm.createDirectory(at: src.appendingPathComponent("x/inner"), withIntermediateDirectories: true)
        try write("file", dst.appendingPathComponent("x"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("x")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(listing(dst.appendingPathComponent("x")) == ["inner"])
        #expect(listing(dst) == ["x"])
    }

    @Test func refusesToOverwriteAFolderWithItsOwnChild() throws {
        let (src, _) = try sandbox()
        // Moving src/x/x (a file) into src would overwrite src/x, which contains the source.
        try fm.createDirectory(at: src.appendingPathComponent("x"), withIntermediateDirectories: true)
        let child = src.appendingPathComponent("x/x")
        try write("precious", child)
        try write("other", src.appendingPathComponent("x/other"))
        let job = FileJob(kind: .move, sources: [child], destinationFolder: src)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(read(child) == "precious")
        #expect(read(src.appendingPathComponent("x/other")) == "other")
        #expect(job.errors.count == 1)
    }

    @Test func overwriteIfOlderComparesDates() throws {
        let (src, dst) = try sandbox()
        let newer = src.appendingPathComponent("a"), older = src.appendingPathComponent("b")
        try write("newer", newer); try write("older", older)
        try write("dst-a", dst.appendingPathComponent("a")); try write("dst-b", dst.appendingPathComponent("b"))
        let now = Date()
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: dst.appendingPathComponent("a").path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: dst.appendingPathComponent("b").path)
        let job = FileJob(kind: .copy, sources: [newer, older], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.overwriteIfOlder, applyToAll: true) }
        _ = try job.run()
        #expect(read(dst.appendingPathComponent("a")) == "newer")
        #expect(read(dst.appendingPathComponent("b")) == "dst-b")
    }

    // MARK: Conflict answers

    @Test func renameToAnExistingNameAsksAgain() throws {
        let (src, dst) = try sandbox()
        try write("new", src.appendingPathComponent("a"))
        try write("A", dst.appendingPathComponent("a"))
        try write("B", dst.appendingPathComponent("b"))
        var asked: [String] = []
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("a")], destinationFolder: dst)
        job.resolveConflict = { info in
            asked.append(info.destination.name)
            return ConflictAnswer(asked.count == 1 ? .rename("b") : .rename("c"))
        }
        _ = try job.run()
        #expect(asked == ["a", "b"])
        #expect(read(dst.appendingPathComponent("b")) == "B")   // not silently overwritten
        #expect(read(dst.appendingPathComponent("c")) == "new")
    }

    @Test func renameToAnInvalidNameFails() throws {
        let (src, dst) = try sandbox()
        try write("new", src.appendingPathComponent("a"))
        try write("old", dst.appendingPathComponent("a"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("a")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.rename("../escape")) }
        _ = try job.run()
        #expect(!exists(root.appendingPathComponent("escape")))
        #expect(job.errors.count == 1)
    }

    @Test func writeIntoOnAFileConflictSkipsInsteadOfDeleting() throws {
        let (src, dst) = try sandbox()
        try write("source", src.appendingPathComponent("f"))
        try write("dest", dst.appendingPathComponent("f"))
        let job = FileJob(kind: .move, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.writeInto) }
        _ = try job.run()
        #expect(read(src.appendingPathComponent("f")) == "source")
        #expect(read(dst.appendingPathComponent("f")) == "dest")
    }

    @Test func applyToAllAsksOnce() throws {
        let (src, dst) = try sandbox()
        for n in ["a", "b", "c"] {
            try write("new", src.appendingPathComponent(n)); try write("old", dst.appendingPathComponent(n))
        }
        var asked = 0
        let job = FileJob(kind: .copy, sources: ["a", "b", "c"].map { src.appendingPathComponent($0) }, destinationFolder: dst)
        job.resolveConflict = { _ in asked += 1; return ConflictAnswer(.skip, applyToAll: true) }
        _ = try job.run()
        #expect(asked == 1)
        #expect(read(dst.appendingPathComponent("c")) == "old")
    }

    @Test func cancelStopsTheJob() throws {
        let (src, dst) = try sandbox()
        try write("1", src.appendingPathComponent("a")); try write("2", src.appendingPathComponent("b"))
        try write("old", dst.appendingPathComponent("a"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("a"), src.appendingPathComponent("b")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.cancel) }
        let undo = try job.run()
        #expect(job.isCancelled && undo == nil)
        #expect(!exists(dst.appendingPathComponent("b")))
    }

    @Test func danglingSymlinkCountsAsConflict() throws {
        let (src, dst) = try sandbox()
        try write("x", src.appendingPathComponent("l"))
        try fm.createSymbolicLink(atPath: dst.appendingPathComponent("l").path, withDestinationPath: "/nonexistent/target")
        var asked = 0
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("l")], destinationFolder: dst)
        job.resolveConflict = { _ in asked += 1; return ConflictAnswer(.skip) }
        _ = try job.run()
        #expect(asked == 1)
    }

    @Test func moveIntoTheSameFolderIsANoOp() throws {
        let (src, _) = try sandbox()
        try write("x", src.appendingPathComponent("f"))
        let job = FileJob(kind: .move, sources: [src.appendingPathComponent("f")], destinationFolder: src)
        job.resolveConflict = { _ in Issue.record("no conflict expected"); return ConflictAnswer(.cancel) }
        #expect(try job.run() == nil)
        #expect(job.results == [src.appendingPathComponent("f")] && listing(src) == ["f"])
    }

    // MARK: Into itself

    @Test func refusesCopyIntoItselfThroughASymlink() throws {
        let (src, _) = try sandbox()
        let a = src.appendingPathComponent("a")
        try fm.createDirectory(at: a.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: a)
        let job = FileJob(kind: .copy, sources: [a], destinationFolder: alias.appendingPathComponent("sub"))
        _ = try job.run()
        #expect(job.errors.count == 1)
        #expect(listing(a.appendingPathComponent("sub")).isEmpty)
    }

    @Test func refusesCopyOntoASymlinkToItself() throws {
        let (src, _) = try sandbox()
        let a = src.appendingPathComponent("a")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: a)
        let job = FileJob(kind: .copy, sources: [a], destinationFolder: alias)
        _ = try job.run()
        #expect(job.errors.count == 1)
        #expect(listing(a).isEmpty)
    }

    @Test func movingASymlinkIntoItsTargetIsAllowed() throws {
        let (src, dst) = try sandbox()
        let link = src.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: dst)
        let job = FileJob(kind: .move, sources: [link], destinationFolder: dst)
        _ = try job.run()
        #expect(job.errors.isEmpty)
        #expect(listing(dst) == ["link"])
    }

    // MARK: Merge

    @Test func mergedMoveUndoRecreatesTheSourceFolder() throws {
        let (src, dst) = try sandbox()
        try fm.createDirectory(at: src.appendingPathComponent("f"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.appendingPathComponent("f"), withIntermediateDirectories: true)
        try write("1", src.appendingPathComponent("f/one"))
        try write("2", dst.appendingPathComponent("f/two"))
        let job = FileJob(kind: .move, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.writeInto) }
        let undo = try #require(try job.run())
        #expect(!exists(src.appendingPathComponent("f")))   // emptied by the merge, then removed
        #expect(listing(dst.appendingPathComponent("f")) == ["one", "two"])
        _ = try FileActions.undo(undo)
        #expect(read(src.appendingPathComponent("f/one")) == "1")
        #expect(listing(dst.appendingPathComponent("f")) == ["two"])
    }

    @Test func mergeContinuesAfterAFailingChild() throws {
        let (src, dst) = try sandbox()
        try fm.createDirectory(at: src.appendingPathComponent("f"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.appendingPathComponent("f"), withIntermediateDirectories: true)
        let bad = src.appendingPathComponent("f/a-unreadable")
        try write("x", bad); try write("y", src.appendingPathComponent("f/b-fine"))
        chmod(bad.path, 0o000)
        defer { chmod(bad.path, 0o644) }
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        job.resolveConflict = { _ in ConflictAnswer(.writeInto) }
        _ = try job.run()
        #expect(listing(dst.appendingPathComponent("f")) == ["b-fine"])
        #expect(job.denied.map(\.lastPathComponent) == ["a-unreadable"], "\(job.errors)")
        #expect(job.deniedTargets.values.map(\.path) == [dst.appendingPathComponent("f/a-unreadable").path])
    }

    @Test func movedSourceSurvivesWhenMergeLeavesItems() throws {
        let (src, dst) = try sandbox()
        try fm.createDirectory(at: src.appendingPathComponent("f"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.appendingPathComponent("f"), withIntermediateDirectories: true)
        try write("mine", src.appendingPathComponent("f/same"))
        try write("theirs", dst.appendingPathComponent("f/same"))
        let job = FileJob(kind: .move, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        job.resolveConflict = { info in ConflictAnswer(info.source.isBrowsableFolder ? .writeInto : .skip) }
        _ = try job.run()
        #expect(read(src.appendingPathComponent("f/same")) == "mine")   // skipped child keeps its folder
    }

    // MARK: Copy details

    @Test func copiesFolderTreesWithProgress() throws {
        let (src, dst) = try sandbox()
        let tree = src.appendingPathComponent("tree")
        try fm.createDirectory(at: tree.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: tree.appendingPathComponent("a/b/f"))
        try Data(count: 500).write(to: tree.appendingPathComponent("g"))
        var last: JobProgress?
        let job = FileJob(kind: .copy, sources: [tree], destinationFolder: dst)
        job.onProgress = { last = $0 }
        let undo = try job.run()
        #expect(FileJob.diskSize(dst.appendingPathComponent("tree")) == 1500)
        #expect(last?.doneBytes == 1500 && last?.fraction == 1)
        guard case .created(let urls)? = undo else { Issue.record("expected .created"); return }
        #expect(urls.map(\.path) == [dst.appendingPathComponent("tree").path])
    }

    @Test func linkCreatesSymlinks() throws {
        let (src, dst) = try sandbox()
        try write("x", src.appendingPathComponent("f"))
        let job = FileJob(kind: .link, sources: [src.appendingPathComponent("f")], destinationFolder: dst)
        _ = try job.run()
        let dest = try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("f").path)
        #expect(dest == src.appendingPathComponent("f").path)
    }

    @Test func diskSizeDoesNotFollowSymlinks() throws {
        let (src, dst) = try sandbox()
        try Data(count: 4096).write(to: dst.appendingPathComponent("big"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: dst)
        #expect(FileJob.diskSize(src.appendingPathComponent("link")) == 0)
        #expect(FileJob.diskSize(src) == 0)
        #expect(FileJob.diskSize(dst) == 4096)
        #expect(FileJob.diskSize(root.appendingPathComponent("missing")) == 0)
    }

    @Test func trashAndUndo() throws {
        let (src, _) = try sandbox()
        let f = src.appendingPathComponent("trash-me-\(UUID().uuidString)")
        try write("x", f)
        let job = FileJob(kind: .trash, sources: [f])
        let undo = try #require(try job.run())
        #expect(!exists(f))
        let redo = try #require(try FileActions.undo(undo))
        #expect(read(f) == "x")
        // Redo puts it back in the Trash; clean up from there.
        _ = try FileActions.undo(redo)
        if case .trashed(let pairs) = undo { try? fm.removeItem(at: pairs[0].inTrash) }
    }

    // MARK: Undo

    @Test func undoIsAllOrNothing() throws {
        let (src, dst) = try sandbox()
        for n in ["a", "b"] { try write(n, dst.appendingPathComponent(n)) }
        // "b" can't go back: its original name was taken in the meantime.
        try write("squatter", src.appendingPathComponent("b"))
        let record = UndoRecord.moved([(from: src.appendingPathComponent("a"), to: dst.appendingPathComponent("a")),
                                       (from: src.appendingPathComponent("b"), to: dst.appendingPathComponent("b"))])
        #expect(throws: (any Error).self) { try FileActions.undo(record) }
        #expect(listing(dst) == ["a", "b"])   // "a" was rolled back
        #expect(read(src.appendingPathComponent("b")) == "squatter")
    }

    @Test func undoCreatedSkipsItemsDeletedSince() throws {
        let (src, _) = try sandbox()
        let gone = src.appendingPathComponent("gone")
        #expect(try FileActions.undo(.created([gone])) == nil)
    }

    @Test func undoRename() throws {
        let (src, _) = try sandbox()
        try write("x", src.appendingPathComponent("a"))
        let b = try FileActions.rename(src.appendingPathComponent("a"), to: "b")
        let redo = try #require(try FileActions.undo(.renamed(from: src.appendingPathComponent("a"), to: b)))
        #expect(read(src.appendingPathComponent("a")) == "x")
        guard case .renamed(let from, let to) = redo else { Issue.record("expected .renamed"); return }
        #expect(from == b && to == src.appendingPathComponent("a"))
    }

    // MARK: FileActions

    @Test func renameValidatesNames() throws {
        let (src, _) = try sandbox()
        let a = src.appendingPathComponent("a")
        try write("x", a)
        try write("y", src.appendingPathComponent("taken"))
        for bad in ["", ".", "..", "x/y", "../up"] {
            #expect(throws: FileOperationError.self) { try FileActions.rename(a, to: bad) }
        }
        #expect(throws: FileOperationError.self) { try FileActions.rename(a, to: "taken") }
        #expect(try FileActions.rename(a, to: "A").lastPathComponent == "A")   // case-only rename
        #expect(listing(src) == ["A", "taken"])
    }

    @Test func makeFileNeverOverwrites() throws {
        let (src, _) = try sandbox()
        _ = try FileActions.makeFile(named: "n.txt", in: src, contents: Data("first".utf8))
        #expect(throws: FileOperationError.self) { try FileActions.makeFile(named: "n.txt", in: src, contents: Data("second".utf8)) }
        #expect(read(src.appendingPathComponent("n.txt")) == "first")
    }

    @Test func makeFileInProtectedFolderIsAPermissionError() throws {
        let (src, _) = try sandbox()
        chmod(src.path, 0o555)
        defer { chmod(src.path, 0o755) }
        do {
            _ = try FileActions.makeFile(named: "n.txt", in: src)
            Issue.record("expected an error")
        } catch {
            #expect(FileJob.isPermissionError(error))   // so the app offers to authenticate
        }
    }

    @Test func makeFolderRefusesDotDot() throws {
        let (src, _) = try sandbox()
        #expect(throws: FileOperationError.self) { try FileActions.makeFolder(named: "a/../../b", in: src) }
        #expect(try FileActions.makeFolder(named: "a/b", in: src).path.hasSuffix("src/a/b"))
        #expect(FileActions.validateName("a/../b", in: src, allowSlash: true)?.isError == true)
        #expect(FileActions.validateName("c/d", in: src, allowSlash: true)?.isError == false)
        #expect(FileActions.validateName("a/b", in: src, allowSlash: false)?.isError == true)
        #expect(FileActions.validateName(" sp ", in: src, allowSlash: false)?.isError == false)
    }

    @Test func permissionErrorDetection() {
        #expect(FileJob.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(FileJob.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FileJob.isPermissionError(wrapped))
        #expect(!FileJob.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(!FileJob.isPermissionError(FileOperationError.cancelled))
    }
}
