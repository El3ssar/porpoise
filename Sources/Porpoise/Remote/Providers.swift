import AppKit
import PorpoiseCore
import Security

// MARK: - SSH / SFTP (sftp://, fish://, ssh://) through the system's ssh

/// Uses the user's own `ssh` (keys, agent, ~/.ssh/config, known_hosts) with a shared connection per host.
///
/// Every remote command is a POSIX `sh` script passed as one single-quoted word (`sh -c '…'`), so it
/// runs the same whatever the login shell is, and every path inside it is single-quoted as well.
final class SSHProvider: RemoteProvider {
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

    /// Ends the shared master connection, if one is up.
    func disconnect() {
        _ = try? Shell.run(ssh, baseArgs + ["-O", "exit", "--", target], timeout: 3)
    }

    private var baseArgs: [String] {
        var a = ["-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.controlDir.path)/cm-%C",
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

    func rootTitle(_ url: URL) -> String { target }

    func list(_ folder: URL) throws -> [FileItem] {
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

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
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

    func upload(_ local: URL, into remoteFolder: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ul-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // "./name" so a name starting with "-" isn't read as a tar option.
        let c = try Shell.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", tmp.path, "-C", local.deletingLastPathComponent().path,
                                               "./" + local.lastPathComponent], env: ["COPYFILE_DISABLE": "1"])
        if c.status != 0 { throw RemoteError.failed(c.err) }
        let r = try run("cd \(shellPath(remoteFolder)) && tar -xf -", stdinFile: tmp)
        try check(r, fallback: "Could not upload “\(local.lastPathComponent)”.")
    }

    func delete(_ remote: [URL]) throws {
        if let top = remote.first(where: isTopFolder) { throw RemoteError.failed("“\(top.path)” is a top folder and can't be deleted.") }
        try exec("rm -rf -- " + remote.map(shellPath).joined(separator: " "))
    }

    func makeFolder(_ remote: URL) throws { try exec("mkdir -p -- \(shellPath(remote))") }

    func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let src = shellPath(remote), dst = shellPath(remote.deletingLastPathComponent().appendingPathComponent(newName))
        let r = try run("if [ -e \(dst) ] || [ -L \(dst) ]; then exit \(Self.existsStatus); fi; mv -- \(src) \(dst)")
        if r.status == Self.existsStatus { throw RemoteError.exists(newName) }
        try check(r, fallback: "Could not rename “\(remote.lastPathComponent)”.")
    }

    /// The trailing "/" makes mv/cp fail instead of renaming when the destination folder is missing.
    func move(_ remote: [URL], into folder: URL) throws {
        try exec("mv -- " + remote.map(shellPath).joined(separator: " ") + " " + shellPath(folder) + "/")
    }

    func copy(_ remote: [URL], into folder: URL) throws {
        try exec("cp -R -p -- " + remote.map(shellPath).joined(separator: " ") + " " + shellPath(folder) + "/")
    }
}

// MARK: - FTP (ftp://, ftps://) through curl

/// FTP through curl. Credentials reach curl on stdin (`--config -`), never on its command line, where
/// any local user could read them with `ps`.
final class FTPProvider: RemoteProvider {
    private let scheme: String
    private let host: String
    private let port: Int?
    private var user: String?
    private var password: String?
    private let curl = "/usr/bin/curl"

    /// curl's exit code for a refused login (CURLE_LOGIN_DENIED).
    private static let loginDenied: Int32 = 67
    private static let connectTimeout = 15

    init(url: URL) {
        scheme = url.scheme?.lowercased() ?? "ftp"
        host = url.host ?? ""
        port = url.port
        user = url.user
        password = url.password
        if let u = user, password == nil { password = Keychain.password(server: host, account: u, scheme: scheme) }
    }

    func rootTitle(_ url: URL) -> String { user.map { "\($0)@\(host)" } ?? host }

    /// ftps:// is FTP with required TLS (`--ssl-reqd`), so curl gets ftp:// either way.
    private func base(_ path: String) -> String {
        var s = "ftp://\(host)"
        if let p = port { s += ":\(p)" }
        return s + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    /// curl URLs are relative to the login folder, so raw FTP commands must be too. Line breaks would
    /// smuggle extra commands onto the control connection, so they are refused.
    private func rel(_ u: URL) throws -> String {
        guard !u.path.contains("\n"), !u.path.contains("\r") else { throw RemoteError.invalidName(u.lastPathComponent) }
        let p = String(u.path.drop(while: { $0 == "/" }))
        return p.isEmpty ? "." : p
    }

    /// curl config with the login, in curl's quoted-string syntax.
    private var credentials: Data? {
        guard let u = user else { return nil }
        let escaped = "\(u):\(password ?? "")".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return Data("user = \"\(escaped)\"\n".utf8)
    }

    /// Runs curl; on a login failure asks for credentials once (and keeps them in the Keychain).
    @discardableResult
    private func curlRun(_ args: [String], stdoutFile: URL? = nil, retry: Bool = true) throws -> Data {
        let login = credentials
        var all = ["-s", "-S", "--connect-timeout", String(Self.connectTimeout)]
        if scheme == "ftps" { all += ["--ssl-reqd"] }
        if login != nil { all += ["--config", "-"] }
        let r = try Shell.run(curl, all + args, stdin: login, stdoutFile: stdoutFile)
        if r.status == Self.loginDenied || r.err.contains("530"), retry, askCredentials() {
            return try curlRun(args, stdoutFile: stdoutFile, retry: false)
        }
        if r.status != 0 {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError.failed(msg.isEmpty ? "FTP error \(r.status)" : msg)
        }
        return r.out
    }

    /// Raw FTP commands (`-Q`); the listing curl fetches afterwards is discarded.
    private func command(_ commands: String...) throws {
        try curlRun(commands.flatMap { ["-Q", $0] } + ["-o", "/dev/null", base("/")])
    }

    private func askCredentials() -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { askCredentials() } }
        let a = NSAlert()
        a.messageText = "Log in to \(host)"
        a.informativeText = "Enter your user name and password for this FTP server."
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        let u = NSTextField(frame: CGRect(x: 0, y: 32, width: 280, height: 24)); u.placeholderString = "User name"; u.stringValue = user ?? ""
        let p = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24)); p.placeholderString = "Password"
        v.addSubview(u); v.addSubview(p)
        a.accessoryView = v
        a.addButton(withTitle: "Log In")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = user == nil ? u : p
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        user = u.stringValue
        password = p.stringValue
        Keychain.save(server: host, account: u.stringValue, password: p.stringValue, scheme: scheme)
        return true
    }

    func list(_ folder: URL) throws -> [FileItem] {
        var path = folder.path.isEmpty ? "/" : folder.path
        if !path.hasSuffix("/") { path += "/" }
        let out = String(decoding: try curlRun([base(path)]), as: UTF8.self)
        return RemoteParsing.parseLsLong(out, folder: folder.appendingPathComponent("", isDirectory: true), timeZone: .gmt)
    }

    private func isDirectory(_ remote: URL) throws -> Bool {
        try list(remote.deletingLastPathComponent()).first { $0.name == remote.lastPathComponent }?.isDirectory ?? false
    }

    private func exists(_ remote: URL) throws -> Bool {
        try list(remote.deletingLastPathComponent()).contains { $0.name == remote.lastPathComponent }
    }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        try RemoteFS.downloadStaged(remote.lastPathComponent, into: localFolder) { staging in
            try fetch(remote, to: staging.appendingPathComponent(remote.lastPathComponent))
        }
    }

    /// `isDir` is known for children (from their folder's listing); only the top item needs a lookup,
    /// instead of listing the parent again for every file.
    private func fetch(_ remote: URL, to dst: URL, isDir known: Bool? = nil) throws {
        if try known ?? isDirectory(remote) {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            for c in try list(remote) { try fetch(c.url, to: dst.appendingPathComponent(c.name), isDir: c.isDirectory) }
        } else {
            try curlRun([base(remote.path)], stdoutFile: dst)
        }
    }

    func upload(_ local: URL, into remoteFolder: URL) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        let target = remoteFolder.appendingPathComponent(local.lastPathComponent)
        if isDir.boolValue {
            try makeFolder(target)
            for c in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) { try upload(c, into: target) }
        } else {
            try curlRun(["--ftp-create-dirs", "-T", local.path, base(target.path)])
        }
    }

    func delete(_ remote: [URL]) throws {
        for r in remote { try delete(r, isDir: nil) }
    }

    private func delete(_ r: URL, isDir known: Bool?) throws {
        let path = try rel(r)
        if path == "." { throw RemoteError.failed("The top folder of \(host) can't be deleted.") }
        if try known ?? isDirectory(r) {
            for c in try list(r) { try delete(c.url, isDir: c.isDirectory) }
            try command("RMD \(path)")
        } else {
            try command("DELE \(path)")
        }
    }

    func makeFolder(_ remote: URL) throws { try command("MKD \(try rel(remote))") }

    /// Most servers let RNTO replace an existing file, so the target is checked first.
    func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let dst = remote.deletingLastPathComponent().appendingPathComponent(newName)
        if try exists(dst) { throw RemoteError.exists(newName) }
        try command("RNFR \(try rel(remote))", "RNTO \(try rel(dst))")
    }

    func move(_ remote: [URL], into folder: URL) throws {
        for r in remote {
            try command("RNFR \(try rel(r))", "RNTO \(try rel(folder.appendingPathComponent(r.lastPathComponent)))")
        }
    }

    func copy(_ remote: [URL], into folder: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ftpcopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for r in remote { try upload(try download(r, into: tmp), into: folder) }
    }
}

// MARK: - Android (adb://SERIAL/path) through adb

/// Android over adb. `adb shell` runs its argument with the device's sh, so paths are single-quoted.
final class ADBProvider: RemoteProvider {
    let serial: String
    private var model: String?
    /// Printed by our rename script when the target exists (older adb doesn't pass exit codes on).
    private static let existsMarker = "__PORPOISE_EXISTS__"

    init(serial: String) { self.serial = serial }

    static var adbPath: String? { AndroidTools.adbPath }

    static func devices() -> [(serial: String, model: String)] {
        guard let adb = adbPath, let r = try? Shell.run(adb, ["devices", "-l"]) else { return [] }
        return RemoteParsing.parseADBDevices(String(decoding: r.out, as: UTF8.self))
    }

    /// Cached: breadcrumbs ask for it on the main thread.
    func rootTitle(_ url: URL) -> String {
        if let m = model { return m }
        guard let m = Self.devices().first(where: { $0.serial == serial })?.model else { return serial }
        model = m
        return m
    }

    private func adb(_ args: [String]) throws -> Data {
        guard let adb = Self.adbPath else {
            throw RemoteError.unsupported("Android support needs adb. Install it with: brew install android-platform-tools — then enable USB debugging on the phone.")
        }
        let r = try Shell.run(adb, ["-s", serial] + args)
        if r.status != 0 { throw RemoteError.failed(r.err.isEmpty ? "adb failed (\(r.status))" : r.err) }
        return r.out
    }

    @discardableResult
    private func shell(_ script: String) throws -> String { String(decoding: try adb(["shell", script]), as: UTF8.self) }

    /// The device root maps to shared storage.
    private func path(_ url: URL) -> String { url.path.isEmpty || url.path == "/" ? "/sdcard" : url.path }
    private func q(_ url: URL) -> String { RemoteParsing.quote(path(url)) }

    func list(_ folder: URL) throws -> [FileItem] {
        let out = try shell("ls -la \(RemoteParsing.quote(path(folder) + "/"))")
        if out.contains("Permission denied") && out.split(separator: "\n").count < 2 { throw RemoteError.failed("Permission denied") }
        var base = URLComponents(url: folder, resolvingAgainstBaseURL: false)
        if folder.path.isEmpty || folder.path == "/" { base?.path = "/sdcard/" }
        let dir = base?.url ?? folder
        return RemoteParsing.parseLsLong(out, folder: dir.appendingPathComponent("", isDirectory: true))
    }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        try RemoteFS.downloadStaged(remote.lastPathComponent, into: localFolder) { staging in
            _ = try adb(["pull", path(remote), staging.path])
        }
    }

    func upload(_ local: URL, into remoteFolder: URL) throws { _ = try adb(["push", local.path, path(remoteFolder) + "/"]) }

    func delete(_ remote: [URL]) throws {
        if let top = remote.first(where: { ["/", "/sdcard", "/sdcard/"].contains(path($0)) }) {
            throw RemoteError.failed("“\(path(top))” is a top folder and can't be deleted.")
        }
        try shell("rm -rf " + remote.map(q).joined(separator: " "))
    }

    func makeFolder(_ remote: URL) throws { try shell("mkdir -p \(q(remote))") }

    func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let dst = q(remote.deletingLastPathComponent().appendingPathComponent(newName))
        let out = try shell("if [ -e \(dst) ]; then echo \(Self.existsMarker); else mv \(q(remote)) \(dst); fi")
        if out.contains(Self.existsMarker) { throw RemoteError.exists(newName) }
    }

    func move(_ remote: [URL], into folder: URL) throws {
        try shell("mv " + remote.map(q).joined(separator: " ") + " " + q(folder) + "/")
    }

    func copy(_ remote: [URL], into folder: URL) throws {
        try shell("cp -r " + remote.map(q).joined(separator: " ") + " " + q(folder) + "/")
    }
}

// MARK: - Keychain (FTP passwords)

/// Internet passwords keyed by server + account (lookups stay compatible with items saved before the
/// protocol attribute was added).
enum Keychain {
    static func password(server: String, account: String, scheme: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(server: String, account: String, password: String, scheme: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
                                kSecAttrAccount as String: account]
        let data = Data(password.utf8)
        // Update in place keeps the item's access settings; add only when there is none yet.
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrProtocol as String] = scheme == "ftps" ? kSecAttrProtocolFTPS : kSecAttrProtocolFTP
        add[kSecAttrLabel as String] = "Porpoise: \(scheme)://\(account)@\(server)"
        SecItemAdd(add as CFDictionary, nil)
    }
}
