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
    static func run(
        _ arguments: [String], in folder: URL, deadline: TimeInterval, limit: Int = 16 * 1024 * 1024,
        extraConfiguration: [String] = []
    ) throws -> Data {
        guard let developerDirectory, FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw Failure.unavailable }
        guard let resolved = realpath(developerDirectory + "/usr/bin/git", nil) else { throw Failure.unavailable }
        let tool = String(cString: resolved); free(resolved)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw Failure.unavailable }
        let escaped = tool.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let profile =
            "(version 1)(deny default (with no-log))(allow file-read*)"
            + "(allow file-write* (literal \"/dev/null\"))(allow process-fork)(allow sysctl-read)"
            + "(allow signal (target self))(allow process-exec (literal \"" + escaped + "\"))"
        let overrides = configuration + extraConfiguration
        let args = overrides.flatMap { ["-c", $0] } + ["--no-pager", "--no-optional-locks"] + arguments
        var env = environment
        env["DEVELOPER_DIR"] = developerDirectory
        env["PATH"] = URL(fileURLWithPath: tool).deletingLastPathComponent().path + ":/usr/bin:/bin"
        // Also propagate overrides to Git's own submodule subprocesses.
        env["GIT_CONFIG_COUNT"] = String(overrides.count)
        for (i, value) in overrides.enumerated() {
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            env["GIT_CONFIG_KEY_\(i)"] = String(pair[0]); env["GIT_CONFIG_VALUE_\(i)"] = String(pair[1])
        }
        return try runProcess(
            "/usr/bin/sandbox-exec", ["-p", profile, tool] + args, in: folder, environment: env, deadline: deadline,
            limit: limit)
    }
    static func runProcess(
        _ tool: String, _ arguments: [String], in folder: URL, environment: [String: String],
        deadline: TimeInterval, limit: Int, mergeErrors: Bool = false
    ) throws -> Data {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
        // Give Git and any local submodule helpers their own process group, so a deadline stops the entire scan.
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw Failure.command }
        defer { close(descriptors[0]) }
        let null = open("/dev/null", O_RDWR)
        guard null >= 0 else { close(descriptors[1]); throw Failure.command }
        defer { close(null) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(descriptors[1]); throw Failure.command }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { close(descriptors[1]); throw Failure.command }
        defer { posix_spawnattr_destroy(&attributes) }
        let changeDirectory: Int32
        if #available(macOS 26.0, *) {
            changeDirectory = posix_spawn_file_actions_addchdir(&actions, folder.path)
        } else {
            changeDirectory = posix_spawn_file_actions_addchdir_np(&actions, folder.path)
        }
        let setup = [
            posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, mergeErrors ? descriptors[1] : null, STDERR_FILENO),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            changeDirectory,
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { close(descriptors[1]); throw Failure.command }
        var argv = ([tool] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; envp.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let launched = posix_spawn(&pid, tool, &actions, &attributes, &argv, &envp)
        close(descriptors[1])
        guard launched == 0 else { throw Failure.unavailable }
        let fd = descriptors[0]
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65536), ended = false
        var status: Int32 = 0, reaped = false
        func reap() {
            if !reaped { reaped = waitpid(pid, &status, WNOHANG) == pid }
        }
        func stop() {
            kill(-pid, SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + 0.05
            while ProcessInfo.processInfo.systemUptime < grace {
                reap(); if reaped { break }; Thread.sleep(forTimeInterval: 0.002)
            }
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        // A descendant retaining stdout after Git exits still consumes the same deadline and is killed with the group.
        while !ended || !reaped {
            if ProcessInfo.processInfo.systemUptime >= deadline { stop(); throw Failure.budget }
            reap()
            if ended { Thread.sleep(forTimeInterval: 0.002); continue }
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
        guard status == 0 else { throw Failure.command }
        return output
    }
    static func path(_ data: Data) throws -> URL {
        // rev-parse emits exactly one final LF; do not trim meaningful whitespace in a folder's name.
        guard data.last == 10, let path = String(data: data.dropLast(), encoding: .utf8), path.hasPrefix("/") else { throw Failure.command }
        return URL(fileURLWithPath: path)
    }
}
