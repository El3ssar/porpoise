import Foundation
import PorpoiseCore

public enum Shell {
    /// Scoped to one synchronous transfer thread: every nested tool inherits pause/cancel controls.
    public final class TransferControl: @unchecked Sendable {
        public var isPaused: () -> Bool
        public var isCancelled: () -> Bool
        public var isInterrupted: () -> Bool
        /// Bytes traversing a file-backed stdin/stdout of the tool (archive overhead may be included).
        public var onBytes: (Int64) -> Void
        public var onStatus: (String?) -> Void
        public var pace: (Int64) throws -> Void = { _ in }
        public var paceAsync: @Sendable (Int64) async throws -> Void = { _ in }
        var managesRetries = false
        var bytesPerSecond: Int64 = 0
        public init(
            isPaused: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
            isInterrupted: @escaping () -> Bool = { false }, onBytes: @escaping (Int64) -> Void = { _ in },
            onStatus: @escaping (String?) -> Void = { _ in }
        ) {
            self.isPaused = isPaused; self.isCancelled = isCancelled; self.isInterrupted = isInterrupted; self.onBytes = onBytes;
            self.onStatus = onStatus
        }
        func check() throws {
            while isPaused() && !isCancelled() && !isInterrupted() { Thread.sleep(forTimeInterval: 0.02) }
            if isInterrupted() { throw FileOperationError.interrupted }
            if isCancelled() { throw FileOperationError.cancelled }
        }
    }
    static var currentTransferControl: TransferControl? { Thread.current.threadDictionary[transferKey] as? TransferControl }
    private static let transferKey = "Porpoise.Shell.transferControl"
    public static func withTransferControl<T>(_ control: TransferControl, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[transferKey]
        dictionary[transferKey] = control
        defer { dictionary[transferKey] = previous }
        return try body()
    }

    /// Best-effort staging cleanup still runs after the transfer's cancellation flag is set.
    static func withoutTransferControl<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[transferKey]
        dictionary.removeObject(forKey: transferKey)
        defer { dictionary[transferKey] = previous }
        return try body()
    }

    public struct Result { public var status: Int32; public var out: Data; public var err: String }

    /// Grace period between SIGTERM and SIGKILL when a timeout expires.
    private static let killGrace: TimeInterval = 2

    /// A new serial queue for a pipe reader/writer or the timeout. Not a global (or concurrent) queue: with callers
    /// blocked in `run` on every worker thread (many runs at once from Swift concurrency's pool) those get no thread,
    /// so the readers never start and every run waits forever. A serial queue gets a thread beyond that limit.
    private static func ioQueue() -> DispatchQueue { DispatchQueue(label: "porpoise.shell-io") }
    private static func isBrokenPipe(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain && current.code == Int(EPIPE) { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
    private static func stopAfterIOFailure(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Self.ioQueue().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Runs a tool synchronously (call off the main thread). `stdinFile`/`stdoutFile` stream large data.
    /// stdin is written and stdout/stderr are drained concurrently, so neither side can block on a full
    /// pipe. With `timeout` > 0 the tool is terminated (then killed) when it runs longer, and the call throws.
    @discardableResult
    public static func run(
        _ tool: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil,
        stdoutFile: URL? = nil, stdinFile: URL? = nil, timeout: TimeInterval = 0
    ) throws -> Result {
        let control = Thread.current.threadDictionary[transferKey] as? TransferControl
        try control?.check()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }

        // Handles we open are ours to close (Process doesn't), or every download would leak a descriptor.
        var opened: [FileHandle] = []
        var inputHandle: FileHandle?
        var outputHandle: FileHandle?
        var inPipe: Pipe?
        defer { opened.forEach { try? $0.close() } }
        let outPipe = Pipe(), errPipe = Pipe()
        if let f = stdoutFile {
            guard FileManager.default.createFile(atPath: f.path, contents: nil) else {
                throw RemoteError.failed("Could not create “\(f.lastPathComponent)”.")
            }
            let h = try FileHandle(forWritingTo: f)
            opened.append(h)
            outputHandle = h
            if control == nil { p.standardOutput = h } else { p.standardOutput = outPipe }
        } else {
            p.standardOutput = outPipe
        }
        p.standardError = errPipe
        if let f = stdinFile {
            let h = try FileHandle(forReadingFrom: f)
            opened.append(h)
            if control != nil { inPipe = Pipe() }
            if let inPipe { p.standardInput = inPipe } else { p.standardInput = h }
            inputHandle = h
        } else if stdin != nil {
            inPipe = Pipe()
            p.standardInput = inPipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        let processEnded = DispatchSemaphore(value: 0)
        if control != nil { p.terminationHandler = { _ in processEnded.signal() } }
        try p.run()

        let io = DispatchGroup()
        let box = OutputBox()
        Self.ioQueue().async(group: io) { box.err = errPipe.fileHandleForReading.readDataToEndOfFile() }
        if stdoutFile == nil {
            Self.ioQueue().async(group: io) { box.out = outPipe.fileHandleForReading.readDataToEndOfFile() }
        } else if let control, let output = outputHandle {
            Self.ioQueue().async(group: io) {
                defer { try? outPipe.fileHandleForReading.close() }
                do {
                    var buffer = [UInt8](repeating: 0, count: 256 << 10)
                    while true {
                        // Foundation may fill a requested read before returning. A pipe must publish even
                        // a single available byte, or a slow tool's progress and pause hooks go silent.
                        let count = buffer.withUnsafeMutableBytes {
                            Darwin.read(outPipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                        }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        if count == 0 { break }
                        let data = Data(buffer.prefix(count))
                        try control.check(); try control.pace(Int64(data.count))
                        try output.write(contentsOf: data)
                        control.onBytes(Int64(data.count))
                    }
                } catch { box.record(error); Self.stopAfterIOFailure(p) }
            }
        }
        if let control, let input = inputHandle, let writer = inPipe?.fileHandleForWriting {
            Self.ioQueue().async(group: io) {
                defer { try? writer.close() }
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                do {
                    while let data = try input.read(upToCount: 256 << 10), !data.isEmpty {
                        try control.check(); try control.pace(Int64(data.count))
                        try writer.write(contentsOf: data)
                        control.onBytes(Int64(data.count))
                    }
                } catch {
                    box.record(error)
                    if !Self.isBrokenPipe(error) { Self.stopAfterIOFailure(p) }
                }
            }
        }
        if let data = stdin, let w = inPipe?.fileHandleForWriting {
            Self.ioQueue().async(group: io) {
                // A tool that exits early must not take the app down with SIGPIPE.
                _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? w.write(contentsOf: data)
                try? w.close()
            }
        }
        let monitor = DispatchGroup()
        if let control {
            Self.ioQueue().async(group: monitor) {
                var suspended = false
                while p.isRunning {
                    if control.isCancelled() {
                        if suspended { _ = p.resume() }
                        p.terminate()
                        Self.ioQueue().asyncAfter(deadline: .now() + killGrace) {
                            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                        }
                        break
                    }
                    if control.isPaused() && !suspended { suspended = p.suspend() }
                    if !control.isPaused() && suspended { _ = p.resume(); suspended = false }
                    _ = processEnded.wait(timeout: .now() + 0.05)
                }
            }
        }
        let watchdog =
            timeout > 0
            ? DispatchWorkItem {
                guard p.isRunning else { return }
                box.timedOut = true
                p.terminate()
                Self.ioQueue().asyncAfter(deadline: .now() + killGrace) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            } : nil
        if let w = watchdog { Self.ioQueue().asyncAfter(deadline: .now() + timeout, execute: w) }
        p.waitUntilExit()
        watchdog?.cancel()
        monitor.wait()
        io.wait()
        try control?.check()
        if let error = box.error {
            // An early failed command may close stdin. Preserve its real diagnostic (for example,
            // permission denied), while a successful command that didn't consume its data is an error.
            if p.terminationStatus == 0 || !Self.isBrokenPipe(error) { throw error }
        }
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
        private var _error: Error?
        var error: Error? { lock.withLock { _error } }
        func record(_ error: Error) { lock.withLock { if _error == nil { _error = error } } }
        var timedOut: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _timedOut }
            set { lock.lock(); _timedOut = newValue; lock.unlock() }
        }
    }

    static func which(_ name: String) -> String? {
        for dir in [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools",
        ] {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
