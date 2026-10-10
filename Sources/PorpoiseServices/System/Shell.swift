import Foundation

public enum Shell {
    public struct Result { public var status: Int32; public var out: Data; public var err: String }

    /// Grace period between SIGTERM and SIGKILL when a timeout expires.
    private static let killGrace: TimeInterval = 2

    /// Feeding stdin and draining stdout/stderr each get a thread of their own. On a dispatch queue they waited for
    /// a free pool thread while the callers held the pool's threads waiting for them: with a few `run`s at once
    /// (Swift concurrency tasks, or blocks on `DispatchQueue.global()`), stdin was never written and all hung.
    private static func onOwnThread(_ group: DispatchGroup, _ work: @escaping () -> Void) {
        group.enter()
        Thread { work(); group.leave() }.start()
    }

    /// Runs a tool synchronously (call off the main thread). `stdinFile`/`stdoutFile` stream large data.
    /// stdin is written and stdout/stderr are drained concurrently, so neither side can block on a full
    /// pipe. With `timeout` > 0 the tool is terminated (then killed) when it runs longer, and the call throws.
    @discardableResult
    public static func run(_ tool: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil,
                    stdoutFile: URL? = nil, stdinFile: URL? = nil, timeout: TimeInterval = 0) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }

        // Handles we open are ours to close (Process doesn't), or every download would leak a descriptor.
        var opened: [FileHandle] = []
        defer { opened.forEach { try? $0.close() } }
        let outPipe = Pipe(), errPipe = Pipe()
        if let f = stdoutFile {
            guard FileManager.default.createFile(atPath: f.path, contents: nil) else {
                throw RemoteError.failed("Could not create “\(f.lastPathComponent)”.")
            }
            let h = try FileHandle(forWritingTo: f)
            opened.append(h)
            p.standardOutput = h
        } else {
            p.standardOutput = outPipe
        }
        p.standardError = errPipe
        var inPipe: Pipe?
        if let f = stdinFile {
            let h = try FileHandle(forReadingFrom: f)
            opened.append(h)
            p.standardInput = h
        } else if stdin != nil {
            inPipe = Pipe()
            p.standardInput = inPipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        try p.run()

        let io = DispatchGroup()
        let box = OutputBox()
        onOwnThread(io) { box.err = errPipe.fileHandleForReading.readDataToEndOfFile() }
        if stdoutFile == nil {
            onOwnThread(io) { box.out = outPipe.fileHandleForReading.readDataToEndOfFile() }
        }
        if let data = stdin, let w = inPipe?.fileHandleForWriting {
            onOwnThread(io) {
                // A tool that exits early must not take the app down with SIGPIPE.
                _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? w.write(contentsOf: data)
                try? w.close()
            }
        }
        let watchdog = timeout > 0 ? DispatchWorkItem {
            guard p.isRunning else { return }
            box.timedOut = true
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        } : nil
        if let w = watchdog { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: w) }
        p.waitUntilExit()
        watchdog?.cancel()
        io.wait()
        if box.timedOut {
            throw RemoteError.failed("“\((tool as NSString).lastPathComponent)” did not finish within \(Int(timeout)) seconds.")
        }
        return Result(status: p.terminationStatus, out: box.out, err: String(decoding: box.err, as: UTF8.self))
    }

    /// Output collected on the reader threads; `io.wait()` orders those writes before the reads.
    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
        private let lock = NSLock()
        private var _timedOut = false
        var timedOut: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _timedOut }
            set { lock.lock(); _timedOut = newValue; lock.unlock() }
        }
    }

    static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin",
                    NSHomeDirectory() + "/Library/Android/sdk/platform-tools"] {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
