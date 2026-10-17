import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

extension DriveMutationTests {
    private func probe(_ server: FakeDriveServer, folder: URL, account: UUID, operation: UUID, mode: String, kind: String, value: String) async throws
        -> Int32
    {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = repo.appendingPathComponent(".build/debug/DriveRecoveryProbe")
        process.arguments = [server.base.absoluteString, folder.path, account.uuidString, operation.uuidString, mode, kind, value]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return try await awaitCallback { continuation in
            // Process.waitUntilExit must not block Swift's cooperative executor or the main actor.
            Thread {
                process.waitUntilExit(); continuation.resume(returning: process.terminationStatus)
            }.start()
        }
    }

    @Test func processDeathBeforeAndAfterRemoteCommitNeverDuplicates() async throws {
        let server = try server(), scratch = try Scratch()
        let account = UUID()
        for mode in ["before", "after"] {
            let op = UUID(), folder = scratch.url.appendingPathComponent(mode)
            #expect(
                try await probe(server, folder: folder, account: account, operation: op, mode: mode, kind: "folder", value: mode)
                    == (mode == "before" ? 91 : 92))
            let journal = DriveMutationJournal(folder: folder)
            #expect(try journal.load(op)?.phase == .requesting)
            #expect(try await probe(server, folder: folder, account: account, operation: op, mode: "resume", kind: "folder", value: mode) == 0)
            let client = try self.client(server, folder: folder, id: account)
            #expect(try await client.list(DriveLocation(accountID: account)).filter { $0.name == mode }.count == 1)
            #expect(try journal.load(op)?.phase == .done)
        }
    }

    @Test func processDeathDuringUploadAndAfterFinalCommitResumesExactBytes() async throws {
        let server = try server(), scratch = try Scratch()
        let account = UUID()
        for mode in ["chunk", "commit"] {
            let folder = scratch.url.appendingPathComponent(mode), op = UUID()
            let source = scratch.url.appendingPathComponent(mode + ".bin")
            let bytes = Data(repeating: 0x53, count: (8 << 20) + 700_003)
            try bytes.write(to: source)
            #expect(
                try await probe(server, folder: folder, account: account, operation: op, mode: mode, kind: "upload", value: source.path)
                    == (mode == "chunk" ? 93 : 94))
            #expect(try await probe(server, folder: folder, account: account, operation: op, mode: "resume", kind: "upload", value: source.path) == 0)
            let client = try self.client(server, folder: folder, id: account)
            let files = try await client.list(DriveLocation(accountID: account))
            let matching = files.filter { $0.name == source.lastPathComponent }
            #expect(matching.count == 1)
            #expect(try await client.download(#require(matching.first)).data == bytes)
        }
    }

    @Test func committedMoveRevalidatesDestinationAndNeverRepeatsUncertainRemoval() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let source = scratch.url.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let target = try await client.upload(source, parentID: "root")
        var record = DriveMutationRecord(operationID: UUID(), accountID: client.accountID, kind: "transferMove")
        record.localSource = source; record.destinationFolder = root; record.fingerprint = JobJournal.Fingerprint(source)
        record.destinationURL = target.location(accountID: client.accountID).url; record.result = target; record.phase = .committed
        try client.mutationJournal.save(record)
        func runtime() -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: .move, sources: [source], destination: root,
                control: JobControl(), rule: .ask, options: .init())
            job.cloudOperations = [source: record.operationID]
            return job
        }
        _ = try await client.rename(target.id, to: "changed")
        let changed = runtime(); await offThePool { changed.run() }
        #expect(changed.errors.count == 1 && FileManager.default.fileExists(atPath: source.path))
        record.result = try await client.file(target.id)
        record.phase = .sourceRemovalPending; try client.mutationJournal.save(record)
        let uncertain = runtime(); await offThePool { uncertain.run() }
        #expect(uncertain.errors.count == 1 && FileManager.default.fileExists(atPath: source.path))
        record.phase = .committed; try client.mutationJournal.save(record)
        let recovered = runtime(); await offThePool { recovered.run() }
        #expect(recovered.errors.isEmpty && !FileManager.default.fileExists(atPath: source.path))
    }
}

extension DriveMutationTests {
    @Test func replaceKeepsIdentityAndPinnedOldBytesAndSkipsIdentical() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let local = scratch.url.appendingPathComponent("replace.bin")
        try Data("original bytes".utf8).write(to: local)
        let original = try await client.upload(local, parentID: "root")
        try Data("replacement bytes".utf8).write(to: local)
        let op = UUID()
        let replacement = try await client.upload(
            local, parentID: "root", operationID: op, replacingID: original.id, expectedVersion: original.version)
        #expect(replacement.id == original.id && replacement.version != original.version)
        #expect(try await client.download(replacement).data == Data("replacement bytes".utf8))
        var revision = URLRequest(url: server.base.appendingPathComponent("drive/v3/files/\(original.id)/revisions/\(original.headRevisionId!)"))
        revision.setValue("Bearer fixture-access", forHTTPHeaderField: "Authorization")
        let (oldBytes, response) = try await URLSession.shared.data(for: revision)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && oldBytes == Data("original bytes".utf8))
        #expect(try client.mutationJournal.load(op)?.previousRevisionID == original.headRevisionId)
        await #expect(throws: DriveMutationError.conflict) {
            try await client.upload(local, parentID: "root", replacingID: original.id, expectedVersion: original.version)
        }
        await #expect(throws: DriveError.permissionDenied) {
            try await client.upload(local, parentID: "root", replacingID: "doc-a")
        }
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let identical = RemoteTransferJob(
            kind: .copy, sources: [local], destination: root,
            control: JobControl(), rule: .different, options: .init(method: .content))
        await offThePool { identical.run() }
        #expect(identical.errors.isEmpty && identical.results.isEmpty)
        #expect(identical.progress.skippedIdenticalItems == 1)
    }

    @Test func expiredUploadRestartsAndCrossDriveMoveTrashesOnlyVerifiedSource() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let local = scratch.url.appendingPathComponent("expired.bin")
        let bytes = Data(repeating: 9, count: 300_000)
        try bytes.write(to: local)
        let operation = UUID()
        let calls = Checkpoints()
        let stop = DriveTransferContext(checkpoint: { if await calls.next() == 2 { throw FileOperationError.interrupted } })
        await #expect(throws: FileOperationError.self) { try await client.upload(local, parentID: "root", operationID: operation, context: stop) }
        try await server.control(["expireSessions": true])
        let uploaded = try await client.upload(local, parentID: "root", operationID: operation)
        #expect(try await client.download(uploaded).data == bytes)
        // A fixture writer with cross-drive relocation permission may copy then trash.
        let move = UUID()
        let result = try await client.move("binary-a", to: "shared-drive-a", operationID: move)
        #expect(result.id != "binary-a" && result.driveId == "shared-drive-a")
        #expect(try await client.file("binary-a", includeTrashed: true).trashed == true)
        #expect(try await client.download(result).data == Data("fixture bytes".utf8))
        #expect(try await client.move("binary-a", to: "shared-drive-a", operationID: move).id == result.id)
        await #expect(throws: DriveError.permissionDenied) { try await client.move("binary-b", to: "shared-drive-a") }
    }
}

extension DriveMutationTests {
    @Test func cancelCleansOnlyOwnedPartialAndPreservesCommittedRemoteObject() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let source = scratch.url.appendingPathComponent("cancel.bin")
        try Data(repeating: 4, count: 600_000).write(to: source)
        let remote = try await client.upload(source, parentID: "root")
        let download = UUID(), calls = Checkpoints()
        let context = DriveTransferContext(checkpoint: { if await calls.next() == 2 { throw FileOperationError.cancelled } })
        await #expect(throws: FileOperationError.self) { try await client.downloadToStaging(remote, operationID: download, context: context) }
        let partial = client.mutationJournal.folder.appendingPathComponent("Downloads/\(download.uuidString).part")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        try await client.cancelTransfer(download)
        #expect(!FileManager.default.fileExists(atPath: partial.path) && FileManager.default.fileExists(atPath: source.path))
        let changed = UUID(), next = Checkpoints()
        await #expect(throws: FileOperationError.self) {
            try await client.downloadToStaging(
                remote, operationID: changed,
                context: .init(checkpoint: { if await next.next() == 2 { throw FileOperationError.cancelled } }))
        }
        let changedPartial = client.mutationJournal.folder.appendingPathComponent("Downloads/\(changed.uuidString).part")
        try Data("user modification".utf8).write(to: changedPartial)
        await #expect(throws: DriveMutationError.sourceChanged) { try await client.cancelTransfer(changed) }
        #expect(try Data(contentsOf: changedPartial) == Data("user modification".utf8))
        let commit = UUID()
        let done = try await client.upload(source, parentID: "root", name: "committed.bin", operationID: commit)
        try await client.cancelTransfer(commit)
        #expect(try await client.file(done.id).id == done.id)
    }

    @Test func nativeTargetAndAmbiguousNamesPreserveSourcesAndNewerSkipsOlder() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let ambiguous = scratch.url.appendingPathComponent("report.txt")
        try Data("original".utf8).write(to: ambiguous)
        let duplicate = RemoteTransferJob(
            kind: .move, sources: [ambiguous], destination: root,
            control: JobControl(), rule: .replace, options: .init())
        await offThePool { duplicate.run() }
        #expect(duplicate.errors.count == 1 && FileManager.default.fileExists(atPath: ambiguous.path))
        let native = scratch.url.appendingPathComponent("Meeting notes")
        try Data("keep native".utf8).write(to: native)
        let replacement = RemoteTransferJob(
            kind: .move, sources: [native], destination: root,
            control: JobControl(), rule: .replace, options: .init())
        await offThePool { replacement.run() }
        #expect(replacement.errors.count == 1 && FileManager.default.fileExists(atPath: native.path))
        let newer = RemoteTransferJob(
            kind: .copy, sources: [native], destination: root,
            control: JobControl(), rule: .newer, options: .init())
        await offThePool { newer.run() }
        #expect(newer.errors.isEmpty && newer.results.isEmpty)
    }
}

extension DriveMutationTests {
    @Test func crossAccountCopiesVerifyBinaryAndExportNativeWithoutRemovingIt() async throws {
        let sourceServer = try server(), targetServer = try server(), scratch = try Scratch()
        let source = try client(sourceServer, folder: scratch.url.appendingPathComponent("source"))
        let destination = try client(targetServer, folder: scratch.url.appendingPathComponent("destination"))
        let sourceProvider = DriveProvider(accountID: source.accountID, client: source)
        let targetProvider = DriveProvider(accountID: destination.accountID, client: destination)
        RemoteFS.registerDrive(sourceProvider, accountID: source.accountID)
        RemoteFS.registerDrive(targetProvider, accountID: destination.accountID)
        defer { RemoteFS.unregisterDrive(accountID: source.accountID); RemoteFS.unregisterDrive(accountID: destination.accountID) }
        let target = try await destination.createFolder(name: "Incoming", parentID: "root").location(accountID: destination.accountID).url
        for id in ["binary-a", "doc-a"] {
            let item = try await source.file(id).location(accountID: source.accountID).url
            let copy = RemoteTransferJob(
                kind: .copy, sources: [item], destination: target,
                control: JobControl(), rule: .ask, options: .init())
            await offThePool { copy.run() }
            #expect(copy.errors.isEmpty && copy.results.count == 1)
            if id == "doc-a", let result = copy.results.first { #expect(targetProvider.metadata(for: result)?.name == "Meeting notes.docx") }
            #expect(try await source.file(id).trashed != true)
        }
        let document = try await source.file("doc-a").location(accountID: source.accountID).url
        let move = RemoteTransferJob(
            kind: .move, sources: [document], destination: target,
            control: JobControl(), rule: .ask, options: .init())
        await offThePool { move.run() }
        let preserved = try await source.file("doc-a")
        #expect(move.errors.count == 1 && preserved.trashed != true)
    }
}

extension DriveMutationTests {
    @Test func failedReplacementLeavesOldBytesAndLostCommitResponseReconciles() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let source = scratch.url.appendingPathComponent("replace-fault.bin")
        try Data("old".utf8).write(to: source)
        let original = try await client.upload(source, parentID: "root")
        try Data("new".utf8).write(to: source)
        for code in [409, 412] {
            try await server.control(["mutationFaults": [0, code]])
            await #expect(throws: DriveError.http(code)) {
                try await client.upload(source, parentID: "root", replacingID: original.id, expectedVersion: original.version)
            }
            #expect(try await client.download(client.file(original.id)).data == Data("old".utf8))
            #expect(try Data(contentsOf: source) == Data("new".utf8))
        }
        let op = UUID()
        try await server.control(["dropUploadResponse": true])
        do {
            _ = try await client.upload(source, parentID: "root", operationID: op, replacingID: original.id); Issue.record("Expected response drop")
        } catch {}
        let recovered = try await client.upload(source, parentID: "root", operationID: op, replacingID: original.id)
        #expect(recovered.id == original.id)
        #expect(try await client.download(recovered).data == Data("new".utf8))
    }
}
