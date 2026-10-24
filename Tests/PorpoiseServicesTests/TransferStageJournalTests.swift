import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct TransferStageJournalTests {
    @Test(arguments: ["claimed", "verified", "deleting"], [false, true])
    func actualProcessDeathRetainsUncertainCopies(_ mode: String, _ replaceTarget: Bool) async throws {
        let s = try Scratch()
        let source = try s.folder("source")
        try s.file("source/a/b/first", "first")
        try s.file("source/z/second", "second")
        let target = s.path("target")
        try FileManager.default.copyItem(at: source, to: target)
        let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/MoveRecoveryProbe")
        let process = Process()
        process.executableURL = probe
        process.arguments = [s.url.path, mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        let journal = TransferStageJournal(folder: s.path("journal"))  // A fresh instance, as at relaunch.
        let record = try #require(try journal.store.all().first)
        #expect(!FileJob.itemExists(at: source))
        if replaceTarget {
            try FileManager.default.moveItem(at: target, to: s.path("old-target"))
            try s.file("target/new", "replacement")
        }
        let retained = journal.recover()
        let restored = mode == "claimed" || (mode == "verified" && replaceTarget)
        if mode != "deleting" {
            #expect(retained.isEmpty)
            #expect(!FileJob.itemExists(at: record.holding))
            #expect(try journal.store.all().isEmpty)
        } else {
            #expect(retained.map(\.url) == [record.holding])
            #expect(FileJob.itemExists(at: record.holding))
        }
        #expect(FileJob.itemExists(at: source) == restored)
        if restored { #expect(CopyVerification.verify(source, replaceTarget ? s.path("old-target") : target).ok) }
        #expect(
            try String(contentsOf: (replaceTarget ? s.path("old-target") : target).appendingPathComponent("a/b/first"), encoding: .utf8) == "first")
    }

    @Test func stagingIdentitySurvivesARealVolumeRemount() throws {
        let s = try Scratch(), disk = try DiskImage(in: s)
        let journal = TransferStageJournal(folder: s.path("journal"))
        let stage = disk.volume.appendingPathComponent(".porpoise-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: stage.appendingPathComponent("file"))
        try journal.stage(stage)
        journal.release(stage)
        try disk.remount()
        #expect(TransferStageJournal(folder: s.path("journal")).recover().isEmpty)
        #expect(!FileJob.itemExists(at: stage))
    }

    @Test func recoveryNeverReplacesAnArrivalAtTheOriginalName() throws {
        let s = try Scratch(), journal = TransferStageJournal(folder: s.path("journal"))
        let source = try s.file("source", "claimed bytes"), target = try s.file("target", "claimed bytes")
        let holding = try s.folder(".porpoise-removal-" + UUID().uuidString)
        try journal.checkpoint(.claimed(holding: holding, source: source, target: target, verified: false))
        let claimed = holding.appendingPathComponent("source")
        #expect(renamex_np(source.path, claimed.path, UInt32(RENAME_EXCL)) == 0)
        journal.release(holding)
        try s.file("source", "arrived")
        #expect(journal.recover().map(\.url) == [holding])
        #expect(s.read("source") == "arrived")
        #expect(try String(contentsOf: claimed, encoding: .utf8) == "claimed bytes")
    }

    @Test func changedContentsAtTheSameTargetInodeRestoreTheWholeSource() throws {
        let s = try Scratch(), journal = TransferStageJournal(folder: s.path("journal"))
        let source = try s.file("source", "claimed bytes"), target = try s.file("target", "claimed bytes")
        let holding = try s.folder(".porpoise-removal-" + UUID().uuidString)
        try journal.checkpoint(.claimed(holding: holding, source: source, target: target, verified: false))
        #expect(renamex_np(source.path, holding.appendingPathComponent("source").path, UInt32(RENAME_EXCL)) == 0)
        try journal.checkpoint(.claimed(holding: holding, source: source, target: target, verified: true))
        journal.release(holding)
        try Data("changed bytes".utf8).write(to: target)
        #expect(journal.recover().isEmpty)
        #expect(s.read("source") == "claimed bytes" && s.read("target") == "changed bytes")
        #expect(try journal.store.all().isEmpty)
    }

    @Test func anUnmountedVolumeIsKeptSilently() throws {
        let s = try Scratch(), journal = TransferStageJournal(folder: s.path("journal"))
        let parent = try s.folder("volume")
        let stage = parent.appendingPathComponent(".porpoise-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try journal.stage(stage)
        journal.release(stage)
        try FileManager.default.moveItem(at: parent, to: s.path("detached-volume"))
        #expect(journal.recover().isEmpty)
        #expect(try journal.store.all().count == 1)
    }

    @Test(arguments: [false, true])
    func journalFailureBeforeCommitRestoresWholeSource(_ atDeletionStart: Bool) throws {
        let s = try Scratch()
        let source = try s.folder("source")
        try s.file("source/a/b/file", "keep")
        try FileManager.default.copyItem(at: source, to: s.path("target"))
        let journal = TransferStageJournal(folder: s.path("journal"))
        let receipt = try LocalMoveRemovalReceipt(
            source: source,
            onCheckpoint: { checkpoint in
                if !atDeletionStart, case .claimed(_, _, _, true) = checkpoint { throw POSIXError(.ENOSPC) }
                if atDeletionStart, case .deleting = checkpoint { throw POSIXError(.ENOSPC) }
                try journal.checkpoint(checkpoint)
            })
        #expect(throws: POSIXError.self) { try receipt.removeSource(afterVerifying: s.path("target")) }
        #expect(CopyVerification.verify(source, s.path("target")).ok)
        #expect(try journal.store.all().isEmpty)
    }

    @Test(arguments: [false, true])
    func recoveryKeepsRollbackStagingAndSkipsLiveJobs(_ preserve: Bool) throws {
        let s = try Scratch()
        let stage = try s.folder(".porpoise-transfer-" + UUID().uuidString)
        try Data("previous target".utf8).write(to: stage.appendingPathComponent("old"))
        let journal = TransferStageJournal(folder: s.path("journal"))
        try journal.stage(stage)
        #expect(journal.recover().isEmpty)
        #expect(FileJob.itemExists(at: stage))
        if preserve { try journal.preserve(stage) } else { journal.release(stage) }
        let relaunched = TransferStageJournal(folder: s.path("journal"))
        #expect(relaunched.recover().isEmpty == !preserve)
        #expect(FileJob.itemExists(at: stage) == preserve)
    }

    @Test func replacedHoldingFolderIsNeverRemoved() throws {
        let s = try Scratch(), journal = TransferStageJournal(folder: s.path("journal"))
        let stage = try s.folder(".porpoise-transfer-" + UUID().uuidString)
        try journal.stage(stage)
        journal.release(stage)
        try FileManager.default.moveItem(at: stage, to: s.path("old-stage"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        #expect(journal.recover().map(\.url) == [stage])
        #expect(FileJob.itemExists(at: stage))
    }

    @Test func remoteDownloadStagesOnTheDestinationVolume() throws {
        let s = try Scratch(), server = try Scratch()
        let disk = try DiskImage(in: s)
        let provider = CountingTransferProvider(root: server.url)
        let remote = URL(string: "sftp://\(UUID().uuidString)/source")!
        try server.file("source", "download")
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        provider.onDownload = {
            #expect((try? FileManager.default.contentsOfDirectory(atPath: disk.volume.path).contains { $0.hasPrefix(".porpoise-transfer-") }) == true)
            #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("source")))
        }
        let journal = TransferStageJournal(folder: s.path("journal"))
        let job = RemoteTransferJob(kind: .copy, sources: [remote], destination: disk.volume, control: JobControl(), rule: .ask, options: .init())
        job.stageJournal = journal
        job.run()
        #expect(job.errors.isEmpty)
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("source"), encoding: .utf8) == "download")
        #expect(try journal.store.all().isEmpty)
    }

    @Test func uploadReadsTheOriginalWithoutALocalSnapshot() throws {
        let s = try Scratch(), server = try Scratch()
        let source = try s.file("source", "upload")
        let remote = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try server.folder("dst")
        let provider = CountingTransferProvider(root: server.url)
        var uploaded = false
        provider.onUploadSource = { url in
            uploaded = true
            #expect(url == source)
        }
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        weak var releasedJob: RemoteTransferJob?
        autoreleasepool {
            let job = RemoteTransferJob(kind: .move, sources: [source], destination: remote, control: JobControl(), rule: .ask, options: .init())
            job.stageJournal = TransferStageJournal(folder: s.path("journal"))
            job.run()
            #expect(uploaded && job.errors.isEmpty && !FileJob.itemExists(at: source))
            releasedJob = job
        }
        #expect(releasedJob == nil)
        #expect(server.read("dst/source") == "upload")
    }
}
