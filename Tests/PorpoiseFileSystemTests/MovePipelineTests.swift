import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

struct MovePipelineTests {
    @Test func deletingOneHardLinkDoesNotRejectItsCapturedAliases() throws {
        let s = try Scratch()
        let source = try s.folder("source")
        let first = try s.file("source/a", "linked bytes")
        try s.folder("source/sub")
        #expect(link(first.path, s.path("source/sub/b").path) == 0)
        try FileManager.default.copyItem(at: source, to: s.path("target"))
        let receipt = try LocalMoveRemovalReceipt(source: source)
        try receipt.removeSource(afterVerifying: s.path("target"))
        #expect(!FileJob.itemExists(at: source))
        #expect(s.read("target/a") == "linked bytes" && s.read("target/sub/b") == "linked bytes")
    }

    @Test func stoppingAfterPublicationKeepsBothWholeCopies() throws {
        let s = try Scratch(), disk = try DiskImage(in: s)
        let source = try s.folder("source")
        try s.file("source/a/b/file", "keep")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        var retained = 0
        job.onEvent = { if case .placed = $0 { job.cancel() } }
        job.onProgress = { retained = $0.retainedCopies }
        _ = try job.run()
        #expect(job.errors.isEmpty)
        #expect(CopyVerification.verify(source, disk.volume.appendingPathComponent("source")).ok)
        #expect(retained == 1)
    }
    @Test func aLateStopFinishesCurrentTreeAndStopsTheNextItem() throws {
        let s = try Scratch(), disk = try DiskImage(in: s)
        let source = try s.folder("source")
        try s.file("source/a/b/first", "first")
        try s.file("source/z/second", "second")
        let next = try s.file("next", "next")
        let job = FileJob(kind: .move, sources: [source, next], destinationFolder: disk.volume)
        var deletions = 0
        job.removalCheckpoint = { checkpoint in
            if case .deleting = checkpoint {
                deletions += 1
                if deletions == 2 { job.cancel() }
            }
        }
        _ = try job.run()
        #expect(deletions == 2)
        #expect(job.errors.isEmpty)
        #expect(!FileJob.itemExists(at: source) && FileJob.itemExists(at: next))
        #expect(job.movedItems[source]?.path == disk.volume.appendingPathComponent("source").path)
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("next")))
    }
    @Test func nestedRemovalReadsEachCopyOnceAndDoesNotPrehash() throws {
        let s = try Scratch()
        let source = try s.folder("source")
        try s.file("source/a/b/c/file", size: 8 << 20)
        try s.symlink("source/a/link", to: "b/c/file")
        try FileManager.default.copyItem(at: source, to: s.path("target"))
        var bytes: Int64 = 0
        let receipt = try LocalMoveRemovalReceipt(source: source, onRead: { bytes += $0 })
        #expect(bytes == 0)
        try receipt.removeSource(afterVerifying: s.path("target"))
        #expect(bytes == 16 << 20)
        #expect(!FileJob.itemExists(at: source))
        #expect(s.listing() == ["target"])
    }

    @Test func stoppingDuringVerificationRestoresTheWholeTree() throws {
        let s = try Scratch()
        let source = try s.folder("source")
        try s.file("source/a/b/file", size: 8 << 20)
        try s.file("source/z", "keep")
        try FileManager.default.copyItem(at: source, to: s.path("target"))
        let cancellation = DiskCancellation()
        var read: Int64 = 0
        let receipt = try LocalMoveRemovalReceipt(
            source: source, cancellation: cancellation,
            onRead: {
                read += $0; if read >= 3 << 20 { cancellation.cancel() }
            })
        #expect(throws: CancellationError.self) { try receipt.removeSource(afterVerifying: s.path("target")) }
        #expect(FileJob.itemExists(at: s.path("source/a/b/file")))
        #expect(s.read("source/z") == "keep")
        #expect(CopyVerification.verify(source, s.path("target")).ok)
        #expect(s.listing() == ["source", "target"])
    }

    @Test func sameSizeEditWithRestoredMtimeIsStillANewGeneration() throws {
        let s = try Scratch()
        let source = try s.file("source", "old")
        let date = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        let receipt = try LocalMoveRemovalReceipt(source: source)
        try s.file("target", "new")
        try Data("new".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        #expect(throws: (any Error).self) { try receipt.removeSource(afterVerifying: s.path("target")) }
        #expect(s.read("source") == "new")
    }

    @Test(arguments: [false, true])
    func specialFilesAreRefusedWithoutOpeningAndDigestDoesNotBlock(_ isSocket: Bool) throws {
        let s = try Scratch("s"), fifo = s.path("special")
        let descriptor = isSocket ? socket(AF_UNIX, SOCK_STREAM, 0) : -1
        defer { if descriptor >= 0 { close(descriptor) } }
        if isSocket {
            #expect(descriptor >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(fifo.path.utf8CString)
            #expect(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(result == 0)
        } else {
            #expect(mkfifo(fifo.path, 0o600) == 0)
        }
        do {
            _ = try LocalMoveRemovalReceipt(source: fifo)
            Issue.record("FIFO receipt must fail")
        } catch {
            #expect(error.localizedDescription.contains("sockets, FIFOs"))
        }
        #expect(throws: POSIXError.self) { try CopyVerification.checkedDigest(fifo, cancellation: DiskCancellation()) }
        #expect(FileJob.itemExists(at: fifo))
    }

    @Test func unreadableDigestPreservesPermissionClassification() throws {
        guard getuid() != 0 else { return }
        let s = try Scratch(), file = try s.file("file", "private")
        #expect(chmod(file.path, 0) == 0)
        defer { _ = chmod(file.path, 0o600) }
        do {
            _ = try CopyVerification.checkedDigest(file, cancellation: DiskCancellation())
            Issue.record("Unreadable file must fail")
        } catch {
            #expect(FileErrorKind.classify(error) == .permission)
        }
    }
}
