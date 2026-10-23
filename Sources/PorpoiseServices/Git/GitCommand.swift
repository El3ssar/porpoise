import Darwin
import Foundation

/// A local, non-interactive Git subprocess. No shell, inherited Git variables, credentials, hooks, locks or lazy fetches.
/// Call only on a background queue. Both the output and wall time are bounded, including a blocked child.
enum GitCommand {
    enum Failure: Error { case unavailable, budget, command }
    static let configuration = [
        "core.fsmonitor=false", "core.hooksPath=/dev/null", "credential.helper=", "core.untrackedCache=false",
        "core.preloadIndex=false", "submodule.recurse=false", "core.pager=cat", "diff.external=", "protocol.allow=never",
    ]
    static let environment = [
        "PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ALLOW_PROTOCOL": "",
    ]
    // /usr/bin/git is an installer shim on Macs without developer tools. Ask xcode-select (which never offers an
    // installation) first, then pin its installed directory for the shim. No GUI or settings changes on absence.
    private static let developerDirectory: String? = {
        let folder = URL(fileURLWithPath: "/")
        guard
            let data = try? runProcess(
                "/usr/bin/xcode-select", ["--print-path"], in: folder, environment: environment,
                deadline: ProcessInfo.processInfo.systemUptime + 0.5, limit: 4096),
            let directory = try? path(data),
            FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("usr/bin/git").path)
        else { return nil }
        return directory.path
    }()
    static func run(_ arguments: [String], in folder: URL, deadline: TimeInterval, limit: Int = 16 * 1024 * 1024) throws -> Data {
        guard let developerDirectory, FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw Failure.unavailable }
        let args = configuration.flatMap { ["-c", $0] } + ["--no-pager", "--no-optional-locks"] + arguments
        var env = environment
        env["DEVELOPER_DIR"] = developerDirectory
        // Also propagate overrides to Git's own submodule subprocesses.
        env["GIT_CONFIG_COUNT"] = String(configuration.count)
        for (i, value) in configuration.enumerated() {
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            env["GIT_CONFIG_KEY_\(i)"] = String(pair[0]); env["GIT_CONFIG_VALUE_\(i)"] = String(pair[1])
        }
        return try runProcess("/usr/bin/git", args, in: folder, environment: env, deadline: deadline, limit: limit)
    }
    private static func runProcess(
        _ tool: String, _ arguments: [String], in folder: URL, environment: [String: String],
        deadline: TimeInterval, limit: Int
    ) throws -> Data {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = folder
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading, fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        defer { try? handle.close(); try? pipe.fileHandleForWriting.close() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65536), ended = false
        func stop() {
            if process.isRunning { process.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 0.05
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.002) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        while !ended {
            if ProcessInfo.processInfo.systemUptime >= deadline { stop(); throw Failure.budget }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= limit else { stop(); throw Failure.budget }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                ended = true
            } else if errno == EAGAIN || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.002)
            } else {
                stop(); throw Failure.command
            }
        }
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline { stop(); throw Failure.budget }
            Thread.sleep(forTimeInterval: 0.002)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.command }
        return output
    }
    static func path(_ data: Data) throws -> URL {
        // rev-parse emits exactly one final LF; do not trim meaningful whitespace in a folder's name.
        guard data.last == 10, let path = String(data: data.dropLast(), encoding: .utf8), path.hasPrefix("/") else { throw Failure.command }
        return URL(fileURLWithPath: path)
    }
}
