import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

/// An active transfer loses only its own throwaway image. No Finder window or physical drive is involved.
@Suite(.serialized) struct OwnedVolumeDisconnectTests {
    @Test func detachedDestinationKeepsSourceAndPreviousTargetAndCanRetry() throws {
        let scratch = try Scratch("owned-disconnect")
        let name = "PPDisconnect"
        let disk = try DiskImage(name: name, megabytes: 64, in: scratch)
        let image = scratch.path("\(name).dmg")
        // Refuse to run a force-detach command against anything outside this exact fixture.
        try #require(disk.volume.deletingLastPathComponent().standardizedFileURL == scratch.url.standardizedFileURL)
        try #require(image.deletingLastPathComponent().standardizedFileURL == scratch.url.standardizedFileURL)
        try #require(Scratch.isMountPoint(disk.volume))
        let source = try scratch.randomFile("incoming.bin", size: 16 << 20, seed: 29)
        let expected = try Data(contentsOf: source)
        let target = disk.volume.appendingPathComponent(source.lastPathComponent)
        let previous = Data("previous destination bytes".utf8)
        try previous.write(to: target)

        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        job.allowsClone = false
        job.resumableSize = 1
        job.publishInterval = 0
        job.resolveConflict = { _ in ConflictAnswer(.overwrite) }
        var detached = false
        var reachedCheckpoint = false
        var detachError: Error?
        defer {
            if detached {
                try? Self.diskTool(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", disk.volume.path, image.path], in: scratch)
            }
        }
        job.onProgress = { progress in
            guard !reachedCheckpoint, progress.doneBytes > 0, progress.doneBytes < progress.totalBytes else { return }
            reachedCheckpoint = true
            do {
                try Self.diskTool(["detach", "-quiet", "-force", disk.volume.path], in: scratch)
                detached = true
            } catch {
                detachError = error
                job.cancel()
            }
        }
        let result = try job.run()
        if let detachError { throw detachError }
        try #require(reachedCheckpoint && detached)
        #expect(result == nil && job.results.isEmpty)
        #expect(!job.errors.isEmpty && job.firstError != nil)
        #expect(job.failedSources == [source] && job.denied.isEmpty)
        #expect(try Data(contentsOf: source) == expected)

        try Self.diskTool(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", disk.volume.path, image.path], in: scratch)
        detached = false
        #expect(try Data(contentsOf: target) == previous)
        // An ordinary retry must still ask about the old name; declining replacement preserves both copies.
        let skip = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        var conflicts = 0
        skip.resolveConflict = { _ in
            conflicts += 1; return ConflictAnswer(.skip)
        }
        #expect(try skip.run() == nil)
        #expect(conflicts == 1 && skip.errors.isEmpty && skip.results.isEmpty)
        #expect(try Data(contentsOf: target) == previous)
        #expect(try Data(contentsOf: source) == expected)

        let recovered = disk.volume.appendingPathComponent("Recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: false)
        let retry = FileJob(kind: .move, sources: [source], destinationFolder: recovered)
        retry.allowsClone = false
        let undo = try #require(try retry.run())
        #expect(retry.errors.isEmpty && !FileJob.itemExists(at: source))
        #expect(try Data(contentsOf: recovered.appendingPathComponent(source.lastPathComponent)) == expected)
        #expect(try Data(contentsOf: target) == previous)
        _ = try FileActions.undo(undo)
        #expect(try Data(contentsOf: source) == expected)
        #expect(try Data(contentsOf: target) == previous)
    }

    /// Share DiskImage's lifecycle lock, including with fixtures in other test processes.
    private static func diskTool(_ arguments: [String], in scratch: Scratch) throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-disk-image-tests-\(getuid()).lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(.EIO) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let log = scratch.path("disk-tool-\(UUID().uuidString).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let timedOut = ended.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = ended.wait(timeout: .now() + 5)
            }
        }
        guard !timedOut, !process.isRunning, process.terminationReason == .exit, process.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Owned image \(arguments[0]) failed: \(diagnostic)"])
        }
    }
}
