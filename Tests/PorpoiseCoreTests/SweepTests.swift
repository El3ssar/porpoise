import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// FolderWatcher with real FSEvents, and FileJob/FileActions cases found in the file-operations sweep.
@Suite(.serialized) struct FolderWatcherLiveTests {
    let fm = FileManager.default

    /// Waits up to `timeout` for `condition`, spinning briefly.
    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// The folder is reached through a symlink (as /tmp and /var are); FSEvents reports real
    /// paths, which must still match the folder as the app names it.
    @Test func reportsChangesInFoldersReachedThroughSymlinks() throws {
        let scratch = try Scratch()
        defer { withExtendedLifetime(scratch) {} }
        let dir = try scratch.symlink("link", to: scratch.folder("real").path)
        #expect(FolderWatcher.realPath(dir.path) != dir.path)   // the case under test
        let lock = NSLock()
        var hits = Set<String>()
        let watcher = FolderWatcher { h in lock.lock(); hits.formUnion(h); lock.unlock() }
        watcher.watch([dir])
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try Data("x".utf8).write(to: dir.appendingPathComponent("new.txt"))
        let got = wait(5) { lock.lock(); defer { lock.unlock() }; return !hits.isEmpty }
        #expect(got)
        lock.lock(); let h = hits; lock.unlock()
        #expect(h == [dir.standardizedFileURL.path])
    }
}

@Suite(.serialized) struct FileOperationSweepTests {
    let fm = FileManager.default

    private let scratch: Scratch

    init() throws { scratch = try Scratch("FileOperationSweep") }

    private func sandbox() throws -> URL { scratch.url }

    /// Volumes without a Trash are told apart from other failures (the app then offers to delete).
    @Test func trashUnsupportedIsRecognized() {
        #expect(FileJob.isTrashUnsupportedError(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)))
        #expect(!FileJob.isTrashUnsupportedError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        #expect(!FileJob.isTrashUnsupportedError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))))
    }

    /// A missing item fails as an ordinary error, not as "no Trash" (which would offer to delete).
    @Test func trashingAMissingItemIsAnError() throws {
        let root = try sandbox()
        let job = FileJob(kind: .trash, sources: [root.appendingPathComponent("missing")])
        #expect(try job.run() == nil)
        #expect(job.errors.count == 1)
        #expect(job.untrashable.isEmpty)
    }

    /// A dangling symlink takes its name, so the New Folder/File dialog must say the name is taken.
    @Test func validateNameSeesDanglingSymlinks() throws {
        let root = try sandbox()
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "/nonexistent-\(UUID())")
        #expect(FileActions.validateName("dangling", in: root, allowSlash: false)?.isError == true)
    }

    /// Copying a file onto itself seen through a symlinked folder must not destroy it.
    @Test func overwriteThroughASymlinkedFolderIsRefused() throws {
        let root = try sandbox()
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: real.appendingPathComponent("f"))
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let job = FileJob(kind: .copy, sources: [real.appendingPathComponent("f")], destinationFolder: alias)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(String(decoding: try Data(contentsOf: real.appendingPathComponent("f")), as: UTF8.self) == "keep")
        #expect(!job.errors.isEmpty)
    }

    /// Duplicate names skip every taken "copy N" name and keep double extensions.
    @Test func duplicateNamesSkipTakenOnes() {
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt", "a copy.txt", "a copy 2.txt"]) == "a copy 3.txt")
        #expect(FileFormat.duplicateName(for: "x.tar.gz", existing: ["x.tar.gz"]) == "x copy.tar.gz")
    }
}
