import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Output is session-only, bounded, and never written to diagnostics or operation history.
@MainActor public final class CustomToolRun: Identifiable {
    public let id = UUID()
    public let name: String
    public private(set) var output = ""
    public private(set) var exitStatus: Int32?
    public private(set) var failure: String?
    public private(set) var cancelled = false
    private let control: CustomToolProcess
    public var isRunning: Bool { exitStatus == nil && failure == nil }
    public var status: String {
        if let failure { return failure }
        if let exitStatus { return cancelled ? "Cancelled · exit \(exitStatus)" : "Exit \(exitStatus)" }
        return cancelled ? "Cancelling…" : "Running"
    }
    fileprivate init(name: String, control: CustomToolProcess) { self.name = name; self.control = control }
    public func cancel() { guard isRunning else { return }; cancelled = true; control.cancel(); CustomToolRunner.notify() }
    fileprivate func updateOutput(_ value: String) { guard isRunning else { return }; output = value; CustomToolRunner.notify() }
    fileprivate func finish(_ result: CustomToolProcess.Result) {
        output = result.output; exitStatus = result.status; failure = result.failed ? "Could not start the executable." : nil
    }
}

@MainActor public final class CustomToolRunner {
    public static let shared = CustomToolRunner()
    public static let changed = Notification.Name("PorpoiseCustomToolRunsChanged")
    public private(set) var runs: [CustomToolRun] = []
    public init() {}
    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
    /// Re-reads the settings by ID: callers cannot smuggle an executable in through a menu or external request.
    @discardableResult public func start(id: UUID, context: CustomToolContext, value: String? = nil) throws -> CustomToolRun {
        guard let tool = Settings.shared.customTools.first(where: { $0.id == id }) else {
            throw CustomToolError.invalid("This tool no longer exists.")
        }
        guard runs.filter(\.isRunning).count < 4 else { throw CustomToolError.invalid("Four tools are running. Wait for one to finish.") }
        let invocation = try tool.invocation(in: context, value: value)
        let control = CustomToolProcess()
        let run = CustomToolRun(name: tool.name, control: control)
        // Keep at most 100 completed commands; running entries are never evicted.
        if runs.count >= 100 { runs.removeAll { !$0.isRunning } }
        runs.insert(run, at: 0); Self.notify()
        DispatchQueue(label: "porpoise.custom-tool").async {
            let result = control.execute(invocation) { output in
                Task { @MainActor in run.updateOutput(output) }
            }
            // Canonical path resolution may perform IO; do it on this command’s worker.
            let refresh = [context.folder] + context.items.map(\.url) + [context.otherFolder].compactMap { $0 }.filter(\.isFileURL)
            let paths = Set(refresh.flatMap { [FilePath.entry($0.path), FilePath.canonical($0.deletingLastPathComponent().path)] })
            Task { @MainActor in
                run.finish(result)
                NotificationCenter.default.post(
                    name: FileOperationsController.foldersChanged, object: nil, userInfo: ["paths": paths, "remote": Set<String>()])
                Self.notify()
            }
        }
        return run
    }
    public func clearFinished() { runs.removeAll { !$0.isRunning }; Self.notify() }
}

/// Owns process state behind a lock; neither launch nor pipe reads block the main thread.
private final class CustomToolProcess: @unchecked Sendable {
    struct Result: Sendable { let output: String; let status: Int32?; let failed: Bool }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        guard let process else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue(label: "porpoise.custom-tool.cancel").asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func execute(_ invocation: CustomToolInvocation, outputChanged: @escaping @Sendable (String) -> Void) -> Result {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: invocation.executable)
        p.arguments = invocation.arguments; p.currentDirectoryURL = invocation.folder
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe; p.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); return Result(output: "", status: -1, failed: false) }
        process = p
        do { try p.run() } catch { process = nil; lock.unlock(); return Result(output: "", status: nil, failed: true) }
        lock.unlock()
        // Close our writer so EOF arrives after the child exits. Drain even after reaching the display cap.
        try? pipe.fileHandleForWriting.close()
        let limit = 1024 * 1024
        var data = Data(), truncated = false
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var lastUpdate = Date.distantPast, endedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // A child may fork a background process that retains stdout. Do not wait forever for its EOF.
            if !p.isRunning { endedAt = endedAt ?? Date() }
            if let endedAt, Date().timeIntervalSince(endedAt) > 1 { break }
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptorEvent, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { if count < 0 && errno == EINTR { continue }; break }
            let remaining = max(0, limit - data.count)
            data.append(contentsOf: buffer.prefix(min(count, remaining))); truncated = truncated || count > remaining
            if Date().timeIntervalSince(lastUpdate) >= 0.25 {
                outputChanged(String(decoding: data, as: UTF8.self)); lastUpdate = Date()
            }
        }
        try? pipe.fileHandleForReading.close()
        p.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        let output = String(decoding: data, as: UTF8.self) + (truncated ? "\n[Output limited to 1 MiB]" : "")
        return Result(output: output, status: p.terminationStatus, failed: false)
    }
}
