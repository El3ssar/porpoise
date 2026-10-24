import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite(.serialized)
struct FilePublicationTests {
    @Test func apfsPublicationUsesItsNativeRenameCapabilities() throws {
        let s = try Scratch(), disk = try DiskImage(in: s)
        let incoming = disk.volume.appendingPathComponent("incoming"), target = disk.volume.appendingPathComponent("target")
        try Data("incoming".utf8).write(to: incoming)
        try FilePublication.renameExclusively(incoming, to: target)
        try Data("replacement".utf8).write(to: incoming)
        var checkpoints = 0
        try FilePublication.replace(
            incoming, at: target,
            dispose: { previous in
                #expect(try String(contentsOf: previous, encoding: .utf8) == "incoming")
                try FileManager.default.removeItem(at: previous)
            }, checkpoint: { _ in checkpoints += 1 })
        #expect(checkpoints == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        #expect(try CopyVerification.directoryNames(disk.volume.path).filter { $0.hasPrefix(".porpoise-replaced-") }.isEmpty)
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func copyMoveAndReplaceOnScratchVolumes(_ fileSystem: String) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPPUB", megabytes: 64, fileSystem: fileSystem, in: s)
        let file = try s.file("file", "first")
        let tree = try s.folder("tree")
        let child = try s.file("tree/sub/child", "tree bytes")
        try s.file("tree/ordinary", "ordinary bytes")
        try s.file("tree/._ordinary", "user sidecar bytes")
        let metadata = Data("metadata".utf8)
        for url in [tree, child] {
            #expect(metadata.withUnsafeBytes { setxattr(url.path, "com.porpoise.test", $0.baseAddress, metadata.count, 0, XATTR_NOFOLLOW) } == 0)
        }
        let copy = FileJob(kind: .copy, sources: [file, tree], destinationFolder: disk.volume)
        _ = try copy.run()
        #expect(copy.errors.isEmpty && copy.denied.isEmpty, "\(copy.errors)")
        #expect(CopyVerification.verify(tree, disk.volume.appendingPathComponent("tree")).ok)
        try Data("replacement".utf8).write(to: file)
        let replace = FileJob(kind: .copy, sources: [file], destinationFolder: disk.volume)
        replace.resolveConflict = { _ in .init(.overwrite) }
        _ = try replace.run()
        #expect(replace.errors.isEmpty, "\(replace.errors)")
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("file"), encoding: .utf8) == "replacement")
        let moved = try s.file("moved", "move bytes")
        let moveIn = FileJob(kind: .move, sources: [moved], destinationFolder: disk.volume)
        _ = try moveIn.run()
        #expect(moveIn.errors.isEmpty && !FileJob.itemExists(at: moved), "\(moveIn.errors)")
        let destination = try s.folder("returned")
        let moveOut = FileJob(
            kind: .move, sources: [disk.volume.appendingPathComponent("moved"), disk.volume.appendingPathComponent("tree")],
            destinationFolder: destination)
        _ = try moveOut.run()
        #expect(moveOut.errors.isEmpty, "\(moveOut.errors)")
        #expect(s.read("returned/moved") == "move bytes" && s.read("returned/tree/sub/child") == "tree bytes")
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("tree")))
        for url in [destination.appendingPathComponent("tree"), destination.appendingPathComponent("tree/sub/child")] {
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = getxattr(url.path, "com.porpoise.test", &bytes, bytes.count, 0, XATTR_NOFOLLOW)
            #expect(count == metadata.count)
            if count >= 0 { #expect(Data(bytes.prefix(count)) == metadata) }
        }
        #expect(try Set(CopyVerification.directoryNames(destination.appendingPathComponent("tree").path)) == ["sub", "ordinary", "._ordinary"])
        #expect(s.read("returned/tree/._ordinary") == "user sidecar bytes")
        #expect(try CopyVerification.directoryNames(destination.appendingPathComponent("tree/sub").path) == ["child"])
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func sameVolumeMoveReplacesFilesAndTrees(_ fileSystem: String, _ directory: Bool) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPPUB", megabytes: 64, fileSystem: fileSystem, in: s)
        let parent = disk.volume.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let source = parent.appendingPathComponent("item"), target = disk.volume.appendingPathComponent("item")
        for (url, bytes) in [(source, "incoming"), (target, "previous")] {
            if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            try Data(bytes.utf8).write(to: directory ? url.appendingPathComponent("child") : url)
        }
        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        job.resolveConflict = { _ in .init(.overwrite) }
        _ = try job.run()
        #expect(job.errors.isEmpty && job.denied.isEmpty, "\(job.errors)")
        #expect(!FileJob.itemExists(at: source))
        #expect(try String(contentsOf: directory ? target.appendingPathComponent("child") : target, encoding: .utf8) == "incoming")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func anArrivalDuringCopyIsNeverOverwritten(_ fileSystem: String, _ directory: Bool) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPPUB", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = directory ? try s.folder("source") : try s.file("source", "incoming")
        if directory { try s.file("source/child", "incoming") }
        let target = disk.volume.appendingPathComponent("source")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        job.onEvent = { event in
            guard case .started = event else { return }
            do {
                if directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    try Data("arrived".utf8).write(to: target.appendingPathComponent("child"))
                } else {
                    try Data("arrived".utf8).write(to: target)
                }
            } catch { Issue.record(error) }
        }
        _ = try job.run()
        #expect(!job.errors.isEmpty && FileJob.itemExists(at: source))
        #expect(try String(contentsOf: directory ? target.appendingPathComponent("child") : target, encoding: .utf8) == "arrived")
    }

    @Test(arguments: [1, 2])
    func failedProtectionNeverHidesEitherGeneration(_ failingWrite: Int) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPPUB", megabytes: 64, fileSystem: "ExFAT", in: s)
        let target = disk.volume.appendingPathComponent("target"), incoming = disk.volume.appendingPathComponent("incoming")
        try Data("previous".utf8).write(to: target)
        try Data("incoming".utf8).write(to: incoming)
        var writes = 0
        #expect(throws: POSIXError.self) {
            try FilePublication.replace(incoming, at: target, dispose: { _ in Issue.record("Must not dispose without protection") }) { checkpoint in
                if case .protecting = checkpoint {
                    writes += 1
                    if writes == failingWrite { throw POSIXError(.ENOSPC) }
                }
            }
        }
        #expect(writes == failingWrite)
        #expect(try String(contentsOf: target, encoding: .utf8) == "previous")
        #expect(try String(contentsOf: incoming, encoding: .utf8) == "incoming")
        #expect(try CopyVerification.directoryNames(disk.volume.path).filter { $0.hasPrefix(".porpoise-replaced-") }.isEmpty)
    }

    @Test(arguments: [ENOTSUP, EACCES, ENOSPC, EIO])
    func fallbackRunsOnlyForUnsupportedExclusiveRename(_ error: Int32) throws {
        let s = try Scratch(), source = try s.file("source", "incoming"), target = s.path("target")
        var reserved = false
        do {
            try FilePublication.renameExclusively(
                source, to: target,
                exclusive: { _, _ in
                    errno = error; return -1
                }, beforeReservedRename: { reserved = true })
            #expect(error == ENOTSUP)
        } catch let failure as POSIXError {
            #expect(failure.code.rawValue == error)
        }
        #expect(reserved == (error == ENOTSUP))
        #expect(s.read(error == ENOTSUP ? "target" : "source") == "incoming")
        #expect(!FileJob.itemExists(at: error == ENOTSUP ? source : target))
    }

    @Test(arguments: [false, true])
    func aChangedReservationKeepsTheNewBytes(_ replaceInode: Bool) throws {
        let s = try Scratch(), source = try s.file("source", "incoming"), target = s.path("target")
        #expect(throws: POSIXError.self) {
            try FilePublication.renameExclusively(
                source, to: target,
                exclusive: { _, _ in
                    errno = ENOTSUP; return -1
                }
            ) {
                if replaceInode { try FileManager.default.removeItem(at: target) }
                try Data("arrived".utf8).write(to: target)
            }
        }
        #expect(s.read("source") == "incoming" && s.read("target") == "arrived")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func aFailedDisposalRollsBackOrRetainsBothGenerations(_ fileSystem: String, _ targetReplaced: Bool) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPPUB", megabytes: 64, fileSystem: fileSystem, in: s)
        let target = disk.volume.appendingPathComponent("target"), incoming = disk.volume.appendingPathComponent("incoming")
        try Data("previous".utf8).write(to: target)
        try Data("incoming".utf8).write(to: incoming)
        do {
            try FilePublication.replace(
                incoming, at: target,
                dispose: { _ in
                    if targetReplaced {
                        try FileManager.default.moveItem(at: target, to: disk.volume.appendingPathComponent("moved-new"))
                        try Data("arrival".utf8).write(to: target)
                    }
                    throw POSIXError(.EACCES)
                })
            Issue.record("Disposal must fail")
        } catch let retained as FilePublication.Retained {
            #expect(targetReplaced)
            let previous =
                FileJob.itemExists(at: retained.holding.appendingPathComponent("Previous/target"))
                ? retained.holding.appendingPathComponent("Previous/target") : retained.holding
            #expect(try String(contentsOf: previous, encoding: .utf8) == "previous")
            #expect(try String(contentsOf: target, encoding: .utf8) == "arrival")
        } catch {
            #expect(!targetReplaced)
            #expect(try String(contentsOf: target, encoding: .utf8) == "previous")
            #expect(try String(contentsOf: incoming, encoding: .utf8) == "incoming")
        }
    }
}
