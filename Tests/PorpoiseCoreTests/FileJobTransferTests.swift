import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

/// What copies, moves and links carry along: nested folders, symlinks, metadata and awkward names.
@Suite struct FileJobTransferTests {
    let fm = FileManager.default

    @Test(arguments: [
        " leading space", "trailing space ", "line\nbreak", "-rf", "--", "emoji 🐬🌊", "quote's \"double\"",
        "$(touch pwned)", "back\\slash", "tab\tname", ".hidden", "a:colon", "日本語のファイル",
    ])
    func awkwardNamesSurviveCopyAndMove(_ name: String) throws {
        let s = try Scratch()
        let src = try s.file("src/\(name)", name)
        try s.folder("copied"); try s.folder("moved")
        _ = try run(.copy, [src], to: s.path("copied"))
        _ = try run(.move, [src], to: s.path("moved"))
        #expect(s.listing("copied") == [name] && s.read("copied/\(name)") == name)
        #expect(s.listing("moved") == [name] && s.read("moved/\(name)") == name)
        #expect(s.listing("src").isEmpty)
        #expect(!FileJob.itemExists(at: s.path("pwned")))
    }

    @Test func copiesNestedFoldersWithTheirSymlinksKeptAsLinks() throws {
        let s = try Scratch()
        try s.file("src/project/docs/guide.md", "guide")
        try s.file("src/project/a/b/c/deep.txt", "deep")
        try s.symlink("src/project/latest", to: "docs/guide.md")
        try s.symlink("src/project/dangling", to: "/nonexistent/porpoise-target")
        try s.symlink("src/project/outside", to: s.path("src").path)
        try s.folder("dst")
        let (job, record) = try run(.copy, [s.path("src/project")], to: s.path("dst"))
        #expect(job.results.map(\.path) == [s.path("dst/project").path])
        #expect(s.read("dst/project/a/b/c/deep.txt") == "deep")
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("dst/project/latest").path) == "docs/guide.md")
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("dst/project/dangling").path) == "/nonexistent/porpoise-target")
        // A link to a folder is copied as the link, not as the folder's contents.
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("dst/project/outside").path) == s.path("src").path)
        guard case .created(let urls)? = record else { Issue.record("expected .created"); return }
        #expect(urls.map(\.path) == [s.path("dst/project").path])
    }

    @Test func aDanglingSymlinkCanBeCopiedAndMovedByItself() throws {
        let s = try Scratch()
        try s.folder("src"); try s.folder("copied"); try s.folder("moved")
        let link = try s.symlink("src/ghost", to: "missing-target")
        _ = try run(.copy, [link], to: s.path("copied"))
        _ = try run(.move, [link], to: s.path("moved"))
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("copied/ghost").path) == "missing-target")
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("moved/ghost").path) == "missing-target")
        #expect(!FileJob.itemExists(at: link))
    }

    @Test func copyKeepsPermissionsDatesExtendedAttributesAndTags() throws {
        let s = try Scratch()
        let f = try s.file("src/tagged.sh", "#!/bin/sh\n")
        try s.folder("dst")
        try setMetadata(f)
        _ = try run(.copy, [f], to: s.path("dst"))
        try expectMetadata(s.path("dst/tagged.sh"))
    }

    @Test func linkPointsAtTheOriginal() throws {
        let s = try Scratch()
        let folder = try s.folder("src/library")
        try s.folder("dst")
        let (job, record) = try run(.link, [folder], to: s.path("dst"))
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("dst/library").path) == folder.path)
        #expect(job.results.map(\.path) == [s.path("dst/library").path])
        guard case .created(let urls)? = record else { Issue.record("expected .created"); return }
        #expect(urls.map(\.path) == [s.path("dst/library").path])
    }

    @Test func linkingIntoTheLinkedFolderItselfIsAllowed() throws {
        let s = try Scratch()
        let folder = try s.folder("library")
        let job = FileJob(kind: .link, sources: [folder], destinationFolder: folder)
        _ = try job.run()
        #expect(job.errors.isEmpty)
        #expect(try fm.destinationOfSymbolicLink(atPath: s.path("library/library").path) == folder.path)
    }

    @Test func sparseFilesCopyWithoutFillingTheDisk() throws {
        let s = try Scratch()
        let big = try s.file("src/disk.img", size: 8 << 30)  // 8 GB of holes
        try s.folder("dst")
        var last: JobProgress?
        let job = FileJob(kind: .copy, sources: [big], destinationFolder: s.path("dst"))
        job.onProgress = { last = $0 }
        _ = try job.run()
        let size = try s.path("dst/disk.img").resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 8 << 30)
        #expect(last?.totalBytes == 8 << 30 && last?.fraction == 1)
    }

    // MARK: Replacing

    @Test func replacingALockedFileKeepsItAndLeavesNoStagedCopy() throws {
        let s = try Scratch()
        let src = try s.file("src/f", "new")
        let old = try s.file("dst/f", "old")
        #expect(chflags(old.path, UInt32(UF_IMMUTABLE)) == 0)
        let job = FileJob(kind: .copy, sources: [src], destinationFolder: s.path("dst"))
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(s.read("dst/f") == "old" && s.listing("dst") == ["f"])
        #expect(job.denied == [src])
    }

    @Test func aMoveThatCannotReplaceALockedFilePutsTheSourceBack() throws {
        let s = try Scratch()
        let src = try s.file("src/f", "new")
        let old = try s.file("dst/f", "old")
        #expect(chflags(old.path, UInt32(UF_IMMUTABLE)) == 0)
        let job = FileJob(kind: .move, sources: [src], destinationFolder: s.path("dst"))
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        #expect(try job.run() == nil)
        #expect(s.read("src/f") == "new")
        #expect(s.read("dst/f") == "old" && s.listing("dst") == ["f"])
    }

    /// A link to a folder meeting a folder of the same name: the link is what was selected, not the folder it points to.
    private func linkMeetsFolder(_ answer: ConflictResolution) throws -> (Scratch, FileJob) {
        let s = try Scratch()
        try s.file("real/photos/1.jpg", "1")
        try s.folder("src")
        try s.symlink("src/photos", to: s.path("real/photos").path)
        try s.file("dst/photos/2.jpg", "2")
        let job = FileJob(kind: .move, sources: [s.path("src/photos")], destinationFolder: s.path("dst"))
        job.resolveConflict = { _ in ConflictAnswer(answer) }
        _ = try job.run()
        #expect(s.listing("real/photos") == ["1.jpg"])
        return (s, job)
    }

    @Test func writeIntoSkipsALinkToAFolder() throws {
        let (s, job) = try linkMeetsFolder(.writeInto)
        #expect(job.errors.isEmpty)
        #expect(s.listing("src") == ["photos"] && s.listing("dst/photos") == ["2.jpg"])
    }

    @Test func replacingAFolderWithALinkToAFolderReplacesItWithTheLink() throws {
        let (s, job) = try linkMeetsFolder(.overwrite)
        #expect(job.errors.isEmpty)
        #expect(s.listing("src").isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.path("dst/photos").path) == s.path("real/photos").path)
    }

    @Test func anInvalidNameForANestedConflictFailsOnlyThatItem() throws {
        let s = try Scratch()
        try s.file("src/f/clash", "new"); try s.file("src/f/fine", "fine")
        try s.file("dst/f/clash", "old")
        let job = FileJob(kind: .copy, sources: [s.path("src/f")], destinationFolder: s.path("dst"))
        job.resolveConflict = { info in ConflictAnswer(info.source.isBrowsableFolder ? .writeInto : .rename("no/slashes")) }
        _ = try job.run()
        #expect(job.errors == ["“no/slashes” is not a valid name."])
        #expect(s.read("dst/f/clash") == "old" && s.read("dst/f/fine") == "fine")
    }

    // MARK: The folder an item is already in

    @Test func pastingIntoItsOwnFolderReachedThroughALinkMakesACopy() throws {
        let s = try Scratch()
        let f = try s.file("docs/plan.txt", "plan")
        let alias = try s.symlink("alias", to: s.path("docs").path)
        let (job, _) = try run(.copy, [f], to: alias)
        #expect(job.results.map(\.lastPathComponent) == ["plan copy.txt"])
        #expect(s.listing("docs") == ["plan copy.txt", "plan.txt"])
    }

    @Test func movingIntoItsOwnFolderReachedThroughALinkDoesNothing() throws {
        let s = try Scratch()
        let f = try s.file("docs/plan.txt", "plan")
        let alias = try s.symlink("alias", to: s.path("docs").path)
        let (job, record) = try run(.move, [f], to: alias)
        #expect(record == nil && job.results == [f])
        #expect(s.listing("docs") == ["plan.txt"])
    }

    // MARK: Into itself

    @Test func refusesToMoveAFolderIntoItsOwnSubfolder() throws {
        let s = try Scratch()
        try s.file("a/b/keep.txt", "keep")
        let job = FileJob(kind: .move, sources: [s.path("a")], destinationFolder: s.path("a/b"))
        #expect(try job.run() == nil)
        #expect(job.errors == [FileOperationError.intoItself("a").errorDescription!])
        #expect(s.listing("a/b") == ["keep.txt"])
    }

    @Test func refusesToCopyAFolderIntoItself() throws {
        let s = try Scratch()
        try s.folder("a")
        let job = FileJob(kind: .copy, sources: [s.path("a")], destinationFolder: s.path("a"))
        _ = try job.run()
        #expect(job.errors.count == 1)
        #expect(s.listing("a").isEmpty)
    }

    @Test func refusesToMoveIntoItselfThroughASymlinkedDestination() throws {
        let s = try Scratch()
        try s.file("a/inner/x", "x")
        try s.symlink("shortcut", to: s.path("a/inner").path)
        let job = FileJob(kind: .move, sources: [s.path("a")], destinationFolder: s.path("shortcut"))
        _ = try job.run()
        #expect(job.errors.count == 1)
        #expect(s.read("a/inner/x") == "x")
    }

    @Test func refusesToCopyIntoItselfThroughADifferentlyCasedPath() throws {
        let s = try Scratch()
        try s.file("Photos/sub/p.jpg", "p")
        let job = FileJob(kind: .copy, sources: [s.path("Photos")], destinationFolder: s.path("photos/sub"))
        _ = try job.run()
        #expect(job.errors == [FileOperationError.intoItself("Photos").errorDescription!])
        #expect(s.listing("Photos/sub") == ["p.jpg"])
    }

    @Test func aSiblingWhoseNameStartsLikeTheSourceIsNotInsideIt() throws {
        let s = try Scratch()
        try s.file("photos/p.jpg", "p")
        try s.folder("photos-backup")
        _ = try run(.copy, [s.path("photos")], to: s.path("photos-backup"))
        #expect(s.read("photos-backup/photos/p.jpg") == "p")
    }
}

/// Copies and moves onto a second volume (an attached disk image): real data copies instead of APFS clones.
@Suite struct FileJobDiskImageTests {
    let fm = FileManager.default

    // MARK: Cancelling

    @Test func cancellingMidCopyRemovesThePartialCopyAndKeepsTheSource() throws {
        let s = try Scratch()
        let disk = try DiskImage(megabytes: 64, in: s)
        let big = s.path("big.bin")
        try Data(repeating: 7, count: 24 << 20).write(to: big)
        let job = FileJob(kind: .move, sources: [big], destinationFolder: disk.volume)
        job.onProgress = { [unowned job] p in
            // The first report comes before any data; waiting past the reporting interval lets the next one,
            // with the copy under way, through at once.
            if p.doneBytes == 0 { Thread.sleep(forTimeInterval: 0.1) } else if p.doneBytes < p.totalBytes { job.cancel() }
        }
        #expect(try job.run() == nil)
        #expect(job.isCancelled && job.errors.isEmpty)
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("big.bin")))
        #expect(FileJob.diskSize(big) == 24 << 20)
    }

    // MARK: Across volumes

    @Test func movingAcrossVolumesCopiesEverythingThenRemovesTheSource() throws {
        let s = try Scratch()
        let disk = try DiskImage(in: s)
        try s.file("src/album/1.txt", "one")
        try s.symlink("src/album/cover", to: "1.txt")
        try setMetadata(s.file("src/album/run.sh", "#!/bin/sh\n"))
        let (job, record) = try run(.move, [s.path("src/album")], to: disk.volume)
        let moved = disk.volume.appendingPathComponent("album")
        #expect(job.results.map(\.path) == [moved.path])
        #expect(!FileJob.itemExists(at: s.path("src/album")))
        #expect(try String(contentsOf: moved.appendingPathComponent("1.txt"), encoding: .utf8) == "one")
        #expect(try fm.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("cover").path) == "1.txt")
        try expectMetadata(moved.appendingPathComponent("run.sh"))

        // Undo brings it back across, and redo takes it over again.
        let undo = try #require(record)
        let redo = try #require(try FileActions.undo(undo))
        #expect(s.read("src/album/1.txt") == "one" && !FileJob.itemExists(at: moved))
        _ = try FileActions.undo(redo)
        #expect(!FileJob.itemExists(at: s.path("src/album")) && FileJob.itemExists(at: moved.appendingPathComponent("1.txt")))
    }

    @Test func aCrossVolumeMoveThatFailsKeepsTheSource() throws {
        let s = try Scratch()
        let disk = try DiskImage(in: s)
        try s.file("src/folder/fine", "fine")
        let locked = try s.file("src/folder/secret/x", "x").deletingLastPathComponent()
        chmod(locked.path, 0)
        let job = FileJob(kind: .move, sources: [s.path("src/folder")], destinationFolder: disk.volume)
        #expect(try job.run() == nil)
        #expect(job.denied == [s.path("src/folder")])
        chmod(locked.path, 0o755)
        #expect(s.read("src/folder/secret/x") == "x" && s.read("src/folder/fine") == "fine")
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("folder")))
    }

    @Test func replacingAcrossVolumesStagesTheCopyFirst() throws {
        let s = try Scratch()
        let disk = try DiskImage(in: s)
        let src = try s.file("report.txt", "new")
        try Data("old".utf8).write(to: disk.volume.appendingPathComponent("report.txt"))
        let job = FileJob(kind: .move, sources: [src], destinationFolder: disk.volume)
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        _ = try job.run()
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("report.txt"), encoding: .utf8) == "new")
        #expect(!FileJob.itemExists(at: src))
        #expect(try fm.contentsOfDirectory(atPath: disk.volume.path).filter { $0.contains("porpoise") }.isEmpty)
    }

    // MARK: Trash (the disk image's own, never the user's)

    @Test func trashGoesToTheVolumesTrashAndUndoPutsItBack() throws {
        let s = try Scratch()
        let disk = try DiskImage(in: s)
        let f = disk.volume.appendingPathComponent("draft.txt")
        try Data("x".utf8).write(to: f)
        let job = FileJob(kind: .trash, sources: [f])
        let record = try #require(try job.run())
        guard case .trashed(let pairs) = record else { Issue.record("expected .trashed"); return }
        #expect(
            pairs.map { $0.inTrash.resolvingSymlinksInPath() } == [
                disk.volume.appendingPathComponent(".Trashes/\(getuid())/draft.txt").resolvingSymlinksInPath()
            ])
        #expect(!FileJob.itemExists(at: f))

        let redo = try #require(try FileActions.undo(record))
        #expect(try String(contentsOf: f, encoding: .utf8) == "x")
        _ = try FileActions.undo(redo)
        #expect(!FileJob.itemExists(at: f) && FileJob.itemExists(at: pairs[0].inTrash))
    }
}

/// Runs a job that should meet no conflicts and no errors.
private func run(
    _ kind: FileOperationKind, _ sources: [URL], to folder: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> (FileJob, UndoRecord?) {
    let job = FileJob(kind: kind, sources: sources, destinationFolder: folder)
    job.resolveConflict = { info in
        Issue.record("Unexpected conflict for “\(info.destination.name)”", sourceLocation: sourceLocation)
        return ConflictAnswer(.cancel)
    }
    let record = try job.run()
    #expect(job.errors.isEmpty && job.denied.isEmpty, "\(job.errors) \(job.denied)", sourceLocation: sourceLocation)
    return (job, record)
}

/// Permissions, a date, an extended attribute and Finder tags: what a copy must carry along.
private func setMetadata(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o750, .modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
        ofItemAtPath: url.path)
    let value = Array("kept".utf8)
    #expect(setxattr(url.path, "com.porpoise.test", value, value.count, 0, 0) == 0)
    try (url as NSURL).setResourceValue(["Blue", "Project"], forKey: .tagNamesKey)
}

private func expectMetadata(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o750, sourceLocation: sourceLocation)
    #expect((attrs[.modificationDate] as? Date) == Date(timeIntervalSince1970: 1_000_000_000), sourceLocation: sourceLocation)
    var buf = [UInt8](repeating: 0, count: 16)
    let n = getxattr(url.path, "com.porpoise.test", &buf, buf.count, 0, 0)
    #expect(n == 4 && String(decoding: buf.prefix(max(n, 0)), as: UTF8.self) == "kept", sourceLocation: sourceLocation)
    let tags = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames
    #expect(Set(tags ?? []) == ["Blue", "Project"], sourceLocation: sourceLocation)
}
