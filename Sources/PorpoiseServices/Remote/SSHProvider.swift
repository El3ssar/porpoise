import CryptoKit
import Foundation
import PorpoiseCore

/// Uses the user's own `ssh` (keys, agent, ~/.ssh/config, known_hosts) with a shared connection per host.
///
/// Every remote command is a POSIX `sh` script passed as one single-quoted word (`sh -c '…'`), and every path inside
/// it is single-quoted as well. The login shell first reads that word, so it must be sh-compatible (bash, zsh, dash…);
/// csh and fish read some quoting differently.
public final class SSHProvider: RemoteProvider {
    let user: String?
    let host: String
    let port: Int?
    private let ssh = "/usr/bin/ssh"

    /// Exit status our scripts use for "the destination already exists".
    private static let existsStatus: Int32 = 3
    /// Seconds an idle shared connection (ControlMaster) stays open after the last command.
    private static let controlPersist = 180
    private static let connectTimeout = 12
    private static let controlDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    init(url: URL) {
        user = url.user
        host = url.host ?? "localhost"
        port = url.port
    }

    private var target: String { user.map { "\($0)@\(host)" } ?? host }

    /// The shared connection's socket. Socket paths are limited to 104 bytes and ssh adds a temporary suffix while
    /// creating it, so instead of ssh's 40-character %C this is a 16-character hash of user, host and port.
    private var controlPath: String {
        let key = "\(user ?? "")@\(host):\(port.map(String.init) ?? "")"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(Self.controlDir.path)/cm-\(hash)"
    }

    /// Ends the shared master connection, if one is up.
    func disconnect() {
        _ = try? Shell.run(ssh, baseArgs + ["-O", "exit", "--", target], timeout: 3)
    }

    private var baseArgs: [String] {
        var a = ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)",
                 "-o", "ControlPersist=\(Self.controlPersist)", "-o", "ConnectTimeout=\(Self.connectTimeout)",
                 "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=30"]
        if let p = port { a += ["-p", String(p)] }
        // Test runs keep host keys out of ~/.ssh/known_hosts.
        if let kh = ProcessInfo.processInfo.environment["PORPOISE_KNOWN_HOSTS"] {
            a += ["-o", "UserKnownHostsFile=\(kh)", "-o", "StrictHostKeyChecking=accept-new"]
        }
        return a
    }

    private var env: [String: String] {
        ["SSH_ASKPASS": AskPass.scriptPath, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }

    /// Remote path as a shell word; "/~/x" (or empty) is relative to the remote home.
    func shellPath(_ url: URL) -> String {
        var p = url.path
        if p.isEmpty || p == "/~" { return "\"$HOME\"" }
        if p.hasPrefix("/~/") { p.removeFirst(3); return "\"$HOME\"/" + RemoteParsing.quote(p) }
        return RemoteParsing.quote(p)
    }

    /// The remote root or home folder, which must never be deleted wholesale.
    private func isTopFolder(_ url: URL) -> Bool { ["", "/", "/~", "/~/"].contains(url.path) }

    /// Runs `script` with the remote `sh`.
    private func run(_ script: String, stdin: Data? = nil, stdinFile: URL? = nil, stdoutFile: URL? = nil) throws -> Shell.Result {
        // A host or user starting with "-" would be read as an ssh option (-oProxyCommand=… runs commands locally).
        guard !host.hasPrefix("-"), !(user ?? "").hasPrefix("-") else { throw RemoteError.failed("Invalid server name “\(target)”.") }
        let args = baseArgs + ["--", target, "sh -c " + RemoteParsing.quote(script)]
        return try Shell.run(ssh, args, env: env, stdin: stdin, stdoutFile: stdoutFile, stdinFile: stdinFile)
    }

    /// Runs `script` and returns its output; a non-zero exit becomes an error with ssh's message.
    @discardableResult
    func exec(_ script: String, stdin: Data? = nil) throws -> Data {
        let r = try run(script, stdin: stdin)
        try check(r, fallback: "ssh to \(host) failed (\(r.status)).")
        return r.out
    }

    private func check(_ r: Shell.Result, fallback: String) throws {
        guard r.status != 0 else { return }
        let t = r.err.split(separator: "\n").filter { !$0.contains("Warning: Permanently added") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw RemoteError.failed(t.isEmpty ? fallback : t)
    }

    public func rootTitle(_ url: URL) -> String { target }

    public func list(_ folder: URL) throws -> [FileItem] {
        // GNU find where available, else BSD stat; records end with NUL so names may contain newlines.
        let script = """
        cd \(shellPath(folder)) || exit 2
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
          LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y%Y\\t%s\\t%T@\\t%m\\t%u\\t%g\\t%l\\t%f\\0'; echo __GNU__
        else
          for f in .* *; do
            case "$f" in .|..) continue;; esac
            if [ -e "$f" ] || [ -L "$f" ]; then stat -f '%HT\\t%z\\t%m\\t%Lp\\t%Su\\t%Sg\\t%Y\\t%N' "./$f" && printf '\\0'; fi
          done; echo __BSD__
        fi
        """
        var out = String(decoding: try exec(script), as: UTF8.self)
        let base = folder.path.hasSuffix("/") ? folder : folder.appendingPathComponent("", isDirectory: true)
        if out.hasSuffix("__BSD__\n") {
            out.removeLast("__BSD__\n".count)
            return RemoteParsing.parseBSDStat(out, folder: base)
        }
        if out.hasSuffix("__GNU__\n") { out.removeLast("__GNU__\n".count) }
        return RemoteParsing.parseFind(out, folder: base)
    }

    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let name = remote.lastPathComponent
        return try RemoteFS.downloadStaged(name, into: localFolder) { staging in
            // tar keeps folders, permissions and times; streamed through the shared connection.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: tmp) }
            // A symlink to a file is downloaded as the file (-h), so opening it opens its content; links
            // to folders and everything else stay as they are.
            let item = RemoteParsing.quote("./" + name)
            let script = "cd \(shellPath(remote.deletingLastPathComponent())) && "
                + "if [ -L \(item) ] && [ -f \(item) ]; then tar -chf - \(item); else tar -cf - \(item); fi"
            try check(try run(script, stdoutFile: tmp), fallback: "Could not download “\(name)”.")
            let x = try Shell.run("/usr/bin/tar", ["-xf", tmp.path, "-C", staging.path])
            if x.status != 0 { throw RemoteError.failed(x.err) }
        }
    }

    public func upload(_ local: URL, into remoteFolder: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ul-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // "./name" so a name starting with "-" isn't read as a tar option.
        let c = try Shell.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", tmp.path, "-C", local.deletingLastPathComponent().path,
                                               "./" + local.lastPathComponent], env: ["COPYFILE_DISABLE": "1"])
        if c.status != 0 { throw RemoteError.failed(c.err) }
        let r = try run("cd \(shellPath(remoteFolder)) && tar -xf -", stdinFile: tmp)
        try check(r, fallback: "Could not upload “\(local.lastPathComponent)”.")
    }

    public func delete(_ remote: [URL]) throws {
        if let top = remote.first(where: isTopFolder) { throw RemoteError.failed("“\(top.path)” is a top folder and can't be deleted.") }
        try exec("rm -rf -- " + remote.map(shellPath).joined(separator: " "))
    }

    public func makeFolder(_ remote: URL) throws { try exec("mkdir -p -- \(shellPath(remote))") }

    public func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let src = shellPath(remote), dst = shellPath(remote.deletingLastPathComponent().appendingPathComponent(newName))
        let r = try run("if [ -e \(dst) ] || [ -L \(dst) ]; then exit \(Self.existsStatus); fi; mv -- \(src) \(dst)")
        if r.status == Self.existsStatus { throw RemoteError.exists(newName) }
        try check(r, fallback: "Could not rename “\(remote.lastPathComponent)”.")
    }

    /// The trailing "/" makes mv/cp fail instead of renaming when the destination folder is missing.
    public func move(_ remote: [URL], into folder: URL) throws {
        try exec("mv -- " + remote.map(shellPath).joined(separator: " ") + " " + shellPath(folder) + "/")
    }

    public func copy(_ remote: [URL], into folder: URL) throws {
        try exec("cp -R -p -- " + remote.map(shellPath).joined(separator: " ") + " " + shellPath(folder) + "/")
    }
}
