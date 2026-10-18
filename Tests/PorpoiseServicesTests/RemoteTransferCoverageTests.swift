import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Copy, move and delete jobs between local folders and remote hosts, against a real sshd (see `SSHServer`). A
/// second host is the same server under another name ("localhost"), with a connection of its own.
@MainActor
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer, .isolatedSettings)
final class RemoteTransferCoverageTests {
    let server = SSHServer.current!
    let local: Scratch
    let fm = FileManager.default

    init() throws {
        local = try Scratch("local")
        RemoteFS.use(server.provider(), for: server.url("/"))
        RemoteFS.use(server.provider(), for: other("/"))
    }

    deinit {
        RemoteFS.use(nil, for: server.url("/"))
        RemoteFS.use(nil, for: other("/"))
    }

    /// The same server's `path` as a second host.
    nonisolated private func other(_ path: String, isDirectory: Bool = false) -> URL {
        var c = URLComponents(url: server.url(path, isDirectory: isDirectory), resolvingAgainstBaseURL: false)!
        c.host = "localhost"
        return c.url!
    }

    private func remote(_ local: URL) -> URL { server.url(local.path) }
    private func remoteFolder(_ local: URL) -> URL { server.url(local.path, isDirectory: true) }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func run(_ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil, conflicts: [ConflictAnswer] = []) async throws -> (
        results: [URL], errors: [String]
    ) {
        let ui = ScriptedUI(conflicts: conflicts)
        let results = try await makeController(ui).perform(kind, urls, to: folder)
        return (results, ui.errors)
    }

    @Test func pathBasedTransfersRunTheSameConflictCases() async throws {
        let directory = try server.folder()
        let file = directory.appendingPathComponent("report.txt")
        let bytes = Data("incoming bytes".utf8)
        try bytes.write(to: file)
        let source = try #require(try server.provider().list(remoteFolder(directory)).first)
        try await TransferConflictParityTests.exerciseRules(source: source, bytes: bytes, scratch: local)
    }

    @Test func downloadsWithCopyAndMove() async throws {
        let dir = try server.folder()
        try write("copied", dir.appendingPathComponent("copy me.txt"))
        try write("moved", dir.appendingPathComponent("move me.txt"))
        let dst = try local.folder("dst")

        let copied = try await run(.copy, [remote(dir.appendingPathComponent("copy me.txt"))], to: dst)
        #expect(copied.errors.isEmpty && copied.results == [dst.appendingPathComponent("copy me.txt")])
        #expect(local.read("dst/copy me.txt") == "copied")
        #expect(read(dir.appendingPathComponent("copy me.txt")) == "copied")

        let moved = try await run(.move, [remote(dir.appendingPathComponent("move me.txt"))], to: dst)
        #expect(moved.errors.isEmpty && moved.results.count == 1)
        #expect(local.read("dst/move me.txt") == "moved")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("move me.txt").path))
    }

    @Test func uploadsWithCopyAndMove() async throws {
        let dir = try server.folder()
        let a = try local.file("a.txt", "a")
        let b = try local.file("b.txt", "b")
        let dest = remoteFolder(dir)

        let copied = try await run(.copy, [a], to: dest)
        #expect(copied.errors.isEmpty && copied.results == [dest.appendingPathComponent("a.txt")])
        #expect(read(dir.appendingPathComponent("a.txt")) == "a" && local.read("a.txt") == "a")

        let moved = try await run(.move, [b], to: dest)
        #expect(moved.errors.isEmpty)
        #expect(read(dir.appendingPathComponent("b.txt")) == "b" && local.read("b.txt") == nil)

        // The name is taken now: the user chooses Skip; the previous bytes remain.
        try local.file("a.txt", "newer")
        let again = try await run(.copy, [a], to: dest, conflicts: [.init(.skip)])
        #expect(again.results.isEmpty && again.errors.isEmpty)
        #expect(read(dir.appendingPathComponent("a.txt")) == "a")
    }

    @Test func remoteDifferentReplacesOnlyChangedFiles() async throws {
        let dir = try server.folder()
        let same = try local.file("src/same", "same")
        let changed = try local.file("src/changed", "incoming")
        try write("same", dir.appendingPathComponent("same"))
        try write("old", dir.appendingPathComponent("changed"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [same, dir.appendingPathComponent("same")] {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let before = JobJournal.Fingerprint(dir.appendingPathComponent("same"))
        Settings.shared.transferConflictRule = .different
        let c = makeController(ScriptedUI())
        _ = try await c.perform(.copy, [same, changed], to: remoteFolder(dir))
        #expect(read(dir.appendingPathComponent("changed")) == "incoming")
        #expect(JobJournal.Fingerprint(dir.appendingPathComponent("same")) == before)
        #expect(c.activities.last?.progress?.skippedIdenticalItems == 1)
        #expect(c.activities.last?.progress?.replacedItems == 1)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".porpoise-transfer-") })
    }

    @Test func stopThenResumeRemoteQueueKeepsFinishedFilesAndCleansStaging() async throws {
        let dir = try server.folder()
        let small = try local.file("src/first.txt", "finished")
        let big = try local.file("src/large.bin", size: 256 << 20)
        let c = makeController(ScriptedUI())
        c.run(.copy, [small, big], to: remoteFolder(dir), window: nil)
        let activity = try #require(c.activities.last)
        #expect(
            await eventually {
                let names = (try? self.fm.contentsOfDirectory(atPath: dir.path)) ?? []
                return self.fm.fileExists(atPath: dir.appendingPathComponent("first.txt").path)
                    && names.contains { $0.hasPrefix(".porpoise-transfer-") }
            })
        c.pause(activity)
        await expectEventually { activity.state == .paused }
        let first = JobJournal.Fingerprint(dir.appendingPathComponent("first.txt"))
        c.cancel(activity)
        #expect(await eventually { activity.state == .cancelled })
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["first.txt"])
        c.resume(activity)
        let resumed = try #require(c.activities.last)
        #expect(await eventually { resumed.state.isEnded })
        #expect(resumed.state == .completed)
        #expect(JobJournal.Fingerprint(dir.appendingPathComponent("first.txt")) == first)
        #expect(JobJournal.Fingerprint(dir.appendingPathComponent("large.bin"))?.size == 256 << 20)
    }

    @Test func copiesAndMovesWithinOneHost() async throws {
        let dir = try server.folder()
        try write("c", dir.appendingPathComponent("src/c.txt"))
        try write("m", dir.appendingPathComponent("src/m.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("dst"), withIntermediateDirectories: true)
        let dest = remoteFolder(dir.appendingPathComponent("dst"))

        let copied = try await run(.copy, [remote(dir.appendingPathComponent("src/c.txt"))], to: dest)
        #expect(copied.errors.isEmpty)
        #expect(read(dir.appendingPathComponent("dst/c.txt")) == "c" && read(dir.appendingPathComponent("src/c.txt")) == "c")

        let moved = try await run(.move, [remote(dir.appendingPathComponent("src/m.txt"))], to: dest)
        #expect(moved.errors.isEmpty)
        #expect(read(dir.appendingPathComponent("dst/m.txt")) == "m" && !fm.fileExists(atPath: dir.appendingPathComponent("src/m.txt").path))

        // Moved into the folder it is already in: nothing to do.
        let stays = try await run(.move, [remote(dir.appendingPathComponent("dst/m.txt"))], to: server.url(dir.appendingPathComponent("dst").path))
        #expect(stays.errors.isEmpty && stays.results.isEmpty && read(dir.appendingPathComponent("dst/m.txt")) == "m")
    }

    @Test func copiesAndMovesBetweenTwoHosts() async throws {
        let dir = try server.folder()
        try write("c", dir.appendingPathComponent("src/c.txt"))
        try write("m", dir.appendingPathComponent("src/m.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("dst"), withIntermediateDirectories: true)
        let dest = other(dir.appendingPathComponent("dst").path, isDirectory: true)

        let copied = try await run(.copy, [remote(dir.appendingPathComponent("src/c.txt"))], to: dest)
        #expect(copied.errors.isEmpty && copied.results == [dest.appendingPathComponent("c.txt")])
        #expect(read(dir.appendingPathComponent("dst/c.txt")) == "c" && read(dir.appendingPathComponent("src/c.txt")) == "c")

        let moved = try await run(.move, [remote(dir.appendingPathComponent("src/m.txt"))], to: dest)
        #expect(moved.errors.isEmpty)
        #expect(read(dir.appendingPathComponent("dst/m.txt")) == "m" && !fm.fileExists(atPath: dir.appendingPathComponent("src/m.txt").path))
    }

    @Test func deletesRemoteAndLocalItemsOfOneSelection() async throws {
        let dir = try server.folder()
        try write("x", dir.appendingPathComponent("x.txt"))
        let mine = try local.file("mine.txt", "y")
        let deleted = try await run(.delete, [remote(dir.appendingPathComponent("x.txt")), mine])
        #expect(deleted.errors.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(local.read("mine.txt") == nil)
    }

    @Test func aFailedRemoteDeleteIsReported() async throws {
        let deleted = try await run(.delete, [server.url("/~")])
        #expect(deleted.errors.count == 1 && deleted.errors[0].contains("top folder"))
        #expect(fm.fileExists(atPath: server.home.path))
    }
}

extension RemoteTransferCoverageTests {
    @Test func driveAndSFTPTransfersBothDirectionsVerifyBeforeSourceRemoval() async throws {
        let fixture = FakeDriveServer.fixture("mutations.json")
        let driveServer = try FakeDriveServer(fixture: fixture)
        let client = try DriveMutationTests().client(driveServer, folder: local.folder("drive-journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let folder = try server.folder()
        let source = folder.appendingPathComponent("ssh-to-drive.txt")
        try write("bytes survive both moves", source)
        let upload = try await run(.move, [remote(source)], to: root)
        #expect(upload.errors.isEmpty && upload.results.count == 1)
        #expect(!fm.fileExists(atPath: source.path))
        let remoteItem = try #require(upload.results.first)
        let destination = try server.folder()
        let download = try await run(.move, [remoteItem], to: remoteFolder(destination))
        #expect(download.errors.isEmpty && download.results.count == 1)
        #expect(read(destination.appendingPathComponent("ssh-to-drive.txt")) == "bytes survive both moves")
        let location = try #require(DriveLocation(url: remoteItem))
        guard case .folder(let id, _) = location.collection else { Issue.record("Expected Drive item identity"); return }
        #expect(try await client.file(id, includeTrashed: true).trashed == true)
    }
}
