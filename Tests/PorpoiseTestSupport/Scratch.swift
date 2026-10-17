import Foundation

/// A throwaway folder for one test, removed when the value goes away. Everything a test creates on disk goes in
/// one of these, so a run never leaves anything behind.
public final class Scratch {
    public let url: URL
    private let fm = FileManager.default

    public init(_ name: String = #function) throws {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        url = fm.temporaryDirectory.appendingPathComponent("porpoise-test-\(safe)-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Ordinary fixtures need no subprocesses. This also keeps hundreds of synchronous process waits off
        // the main actor during a full parallel run; locked/read-only leftovers still use the recovery below.
        do { try fm.removeItem(at: url); return } catch {}
        guard fm.fileExists(atPath: url.path) else { return }
        // Locked or read-only leftovers must not survive the test either.
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/chflags"), arguments: ["-R", "nouchg", url.path]).waitUntilExit()
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", url.path]).waitUntilExit()
        try? fm.removeItem(at: url)
        guard fm.fileExists(atPath: url.path) else { return }
        // Something is still mounted inside (an image whose attach finished late): detach it, then try again.
        for case let u as URL in fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) ?? .init()
        where Self.isMountPoint(u) {
            try? DiskImage.hdiutil(["detach", "-quiet", "-force", u.path])
        }
        try? fm.removeItem(at: url)
    }

    /// Whether `u` is the root of another volume.
    public static func isMountPoint(_ u: URL) -> Bool {
        var a = stat(), b = stat()
        return lstat(u.path, &a) == 0 && lstat(u.deletingLastPathComponent().path, &b) == 0 && a.st_dev != b.st_dev
    }

    public func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    public func file(_ relative: String, _ contents: String = "", size: Int? = nil) throws -> URL {
        let u = path(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size {
            // Sparse: a large file without writing its bytes.
            guard fm.createFile(atPath: u.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let h = try FileHandle(forWritingTo: u)
            try h.truncate(atOffset: UInt64(size))
            try h.close()
        } else {
            try Data(contents.utf8).write(to: u)
        }
        return u
    }

    @discardableResult
    public func folder(_ relative: String) throws -> URL {
        let u = path(relative)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    public func symlink(_ relative: String, to target: String) throws -> URL {
        let u = path(relative)
        try fm.createSymbolicLink(atPath: u.path, withDestinationPath: target)
        return u
    }

    /// Names directly inside `relative`, sorted.
    public func listing(_ relative: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path(relative).path)) ?? []).sorted()
    }

    public func read(_ relative: String) -> String? { try? String(contentsOf: path(relative), encoding: .utf8) }
}

/// A small disk image attached for one test: a second volume (cross-volume moves, a volume's own Trash), detached
/// and deleted when the value goes away. Nothing shows in Finder (`-nobrowse`).
public final class DiskImage {
    public let volume: URL
    private let image: URL
    /// Kept alive until the image is detached: the image and its mount point live in it.
    private let scratch: Scratch
    /// DiskImages' APFS formatter shares OS state with attach/detach. Concurrent lifecycle commands
    /// sporadically fail creation with ENOTEMPTY. The file lock below also coordinates separate test processes.
    private static let commandLock = NSLock()
    /// Formatting (`hdiutil create -fs APFS`: attach, newfs, eject) fails with "Directory not empty" whenever any disk
    /// image on the Mac is attached or detached meanwhile, by another worktree's tests (some without the lock below),
    /// the system or anything else, which no lock here can hold back. So each name and size is formatted once, into
    /// a template kept in the temporary folder, and every fixture is an APFS clone of it: instant, and never formatted.
    /// Larger images (benchmarks) are created as they are needed, not kept.
    private static let largestTemplate = 256

    public init(name: String = "PorpoiseTest", megabytes: Int = 20, in scratch: Scratch) throws {
        self.scratch = scratch
        image = scratch.path("\(name).dmg")
        volume = scratch.path("mnt-\(name)")
        if megabytes <= Self.largestTemplate {
            try FileManager.default.copyItem(at: Self.template(name: name, megabytes: megabytes), to: image)
        } else {
            try Self.hdiutil(["create", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", name, image.path])
        }
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        do {
            try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", volume.path, image.path])
        } catch {
            // Given up on, the attach may still finish: leave nothing attached behind.
            try? Self.hdiutil(["detach", "-quiet", "-force", volume.path])
            throw error
        }
    }

    deinit { try? Self.hdiutil(["detach", "-quiet", "-force", volume.path]) }

    /// The formatted, never attached image every fixture of that name and size is cloned from; made the first time.
    private static func template(name: String, megabytes: Int) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("porpoise-disk-image-templates-\(getuid())", isDirectory: true)
        let template = folder.appendingPathComponent("\(name)-\(megabytes)m.dmg")
        if fm.fileExists(atPath: template.path) { return template }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = folder.appendingPathComponent("making-\(UUID().uuidString).dmg")
        defer { try? fm.removeItem(at: made) }
        // Made only once per machine, but even then something else may attach or detach an image meanwhile: the
        // formatter's own failure for that is tried again (only that one).
        for attempt in 1...3 {
            do {
                try hdiutil(["create", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", name, made.path])
                break
            } catch let error as CocoaError where attempt < 3 && "\(error.userInfo)".contains("Directory not empty") {
                try? fm.removeItem(at: made)
            }
        }
        // Another process may have made it meanwhile: either one is the same empty volume.
        guard rename(made.path, template.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return template
    }

    /// Runs hdiutil, giving up after a minute (a stuck disk image must fail the test, not hang the run).
    fileprivate static func hdiutil(_ args: [String]) throws {
        commandLock.lock()
        defer { commandLock.unlock() }
        // A test process/worktree must not format while another fixture attaches or detaches. Keep the
        // advisory lock inode in place: unlinking it would let a new caller lock a different inode.
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-disk-image-tests-\(getuid()).lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lockFD) }
        while flock(lockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-hdiutil-\(UUID()).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = handle
        p.standardError = handle
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        try p.run()
        // Completion is an event; the deadline only catches a stuck tool. No polling delays or pipe-reader
        // tasks compete with the test runner's cooperative threads. A file also keeps failure output intact.
        let timedOut = ended.wait(timeout: .now() + 60) == .timedOut
        if timedOut {
            p.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                _ = ended.wait(timeout: .now() + 5)
            }
        }
        guard !timedOut, !p.isRunning, p.terminationReason == .exit, p.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let status = p.isRunning ? "still running" : "\(p.terminationReason), status \(p.terminationStatus)"
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSLocalizedDescriptionKey: "hdiutil \(args[0]) failed (\(status), timed out: \(timedOut)): \(diagnostic)"])
        }
    }
}
