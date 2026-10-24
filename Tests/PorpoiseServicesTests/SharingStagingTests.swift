import Darwin
import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct SharingStagingTests {
    private var future: Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 1200) }

    @Test func releasingLeaseUnlocksDescriptorsInheritedBeforeExec() throws {
        let scratch = try Scratch(), fm = FileManager.default
        let root = try scratch.folder(SharingStaging.rootName)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let name = "Porpoise-Share-" + UUID().uuidString
        let folder = try scratch.folder(SharingStaging.rootName + "/" + name)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(rootFD >= 0)
        let folderFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folderFD >= 0 else { close(rootFD); throw POSIXError(.EIO) }
        guard flock(folderFD, LOCK_EX | LOCK_NB) == 0 else {
            close(folderFD); close(rootFD); throw POSIXError(.EIO)
        }
        var lease: SharingStagingLease? = SharingStagingLease(folder: folder, rootFD: rootFD, folderFD: folderFD, name: name)
        // dup shares the open-file description just like fork: CLOEXEC does not close the child's
        // inherited descriptor until exec. Keep that descriptor open across the parent's release.
        let inherited = dup(folderFD)
        try #require(inherited >= 0)
        defer { close(inherited) }
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
        weak let releasedLease = lease
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(releasedLease == nil)
        #expect(SharingStaging.sweep(root: root, now: future) == 1)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func liveLeaseProtectsOldCopiesAndReleasedLeaseAllowsCrashCleanup() throws {
        let scratch = try Scratch(), fm = FileManager.default
        var lease: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        let folder = try #require(lease?.folder), root = folder.deletingLastPathComponent()
        let outside = try scratch.file("outside/original", "original")
        try fm.createDirectory(at: folder.appendingPathComponent("tree"), withIntermediateDirectories: false)
        try Data("private".utf8).write(to: folder.appendingPathComponent("tree/copy"))
        try fm.createSymbolicLink(at: folder.appendingPathComponent("tree/link"), withDestinationURL: outside.deletingLastPathComponent())
        #expect(try fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
        #expect(fm.fileExists(atPath: folder.path))
        lease = nil  // Simulates the process exiting: its kernel lease disappears.
        #expect(SharingStaging.sweep(root: root, now: future) == 1)
        #expect(!fm.fileExists(atPath: folder.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    }

    @Test func anotherProcessesLeaseSurvivesTheLaunchSweep() throws {
        let scratch = try Scratch()
        var lease: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        let folder = try #require(lease?.folder), root = folder.deletingLastPathComponent()
        lease = nil
        let process = Process(), input = Pipe(), ready = scratch.path("ready")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,os,pathlib,sys; fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); sys.stdin.read(1)",
            folder.path, ready.path,
        ]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
        try input.fileHandleForWriting.write(contentsOf: Data("q".utf8))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(SharingStaging.sweep(root: root, now: future) == 1)
    }

    @Test func graceFutureDatesAndUnrelatedNamesArePreserved() throws {
        let scratch = try Scratch(), fm = FileManager.default, now = future
        var stale: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        var recent: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        var boundary: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        var ahead: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        let staleFolder = try #require(stale?.folder), recentFolder = try #require(recent?.folder)
        let boundaryFolder = try #require(boundary?.folder), aheadFolder = try #require(ahead?.folder)
        let root = staleFolder.deletingLastPathComponent()
        stale = nil; recent = nil; boundary = nil; ahead = nil
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-601)], ofItemAtPath: staleFolder.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: recentFolder.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: boundaryFolder.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(100)], ofItemAtPath: aheadFolder.path)
        let unrelated = root.appendingPathComponent("Porpoise-Share-not-a-uuid")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
        #expect(SharingStaging.sweep(root: root, now: now) == 1)
        for kept in [recentFolder, boundaryFolder, aheadFolder, unrelated] { #expect(fm.fileExists(atPath: kept.path)) }
        #expect(!fm.fileExists(atPath: staleFolder.path))
    }

    @Test func untrustedRootAndCandidateSymlinksAreNeverFollowed() throws {
        let scratch = try Scratch(), fm = FileManager.default
        let outside = try scratch.folder("outside"), file = try scratch.file("outside/original", "original")
        let root = scratch.url.appendingPathComponent(SharingStaging.rootName)
        try fm.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SharingStaging.create(in: scratch.url) }
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
        try fm.removeItem(at: root)
        var lease: SharingStagingLease? = try SharingStaging.create(in: scratch.url)
        let folder = try #require(lease?.folder)
        lease = nil
        try fm.removeItem(at: folder)
        try fm.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try SharingStaging.create(in: scratch.url) }
        #expect(SharingStaging.sweep(root: root, now: future) == 0)
    }

    @Test func candidatesMustBeDirectoriesOwnedByThisUser() {
        var info = stat()
        info.st_mode = mode_t(S_IFDIR | 0o700); info.st_uid = getuid()
        #expect(SharingStaging.eligible(info, now: future))
        info.st_uid = getuid() + 1
        #expect(!SharingStaging.eligible(info, now: future))
        info.st_uid = getuid(); info.st_mode = mode_t(S_IFLNK | 0o700)
        #expect(!SharingStaging.eligible(info, now: future))
    }
}

@MainActor struct SharingQuitDeadlineTests {
    @Test func blockedDeletionHasBoundedExactlyOnceMainQueueReplies() async throws {
        let scratch = try Scratch(), folder = try scratch.folder("staged")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), removed = DispatchSemaphore(value: 0)
        let queue = SharingCleanupQueue { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            removed.signal()
        }
        defer { release.signal() }
        queue.schedule(folder, after: 600)
        var replies = 0
        let first = queue.finishBeforeQuit(timeout: 0.05) {
            #expect(Thread.isMainThread); replies += 1
        }
        let second = queue.finishBeforeQuit(timeout: 0.05) {
            #expect(Thread.isMainThread); replies += 1
        }
        #expect(first && second)
        try #require(await offThePool { entered.wait(timeout: .now() + 3) == .success })
        try #require(await eventually { replies == 2 })
        release.signal()
        try #require(await offThePool { removed.wait(timeout: .now() + 3) == .success })
        try await Task.sleep(for: .milliseconds(100))
        #expect(replies == 2)
        let empty = queue.finishBeforeQuit { Issue.record("An empty queue must not reply") }
        #expect(!empty)
    }
}
