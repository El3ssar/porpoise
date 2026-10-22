import Foundation
import PorpoiseCore

/// FTP through curl. Credentials reach curl on stdin (`--config -`), never on its command line, where
/// any local user could read them with `ps`.
final class FTPProvider: RemoteProvider {
    private let scheme: String
    private let host: String
    private let port: Int?
    private let login: FTPLoginState
    private let curl: String
    private let credentialStore: any PasswordCredentialStore
    private let reconnect: ReconnectPolicy
    /// Sleeps between reconnection tries; tests record instead.
    var wait: (TimeInterval) -> Void = SSHProvider.waitUnlessCancelled
    /// Whether a command ever reached the server: only then is a lost connection worth trying again.
    private var connected: Bool {
        get { stateLock.withLock { everConnected } }
        set { stateLock.withLock { everConnected = newValue } }
    }
    private var everConnected = false
    private let stateLock = NSLock()

    /// curl's exit code for a refused login (CURLE_LOGIN_DENIED).
    private static let loginDenied: Int32 = 67
    private static let connectTimeout = 15

    /// Tests pass their own `curl` (which records what it gets) and a memory credential store.
    init(
        url: URL, curl: String = "/usr/bin/curl", credentialStore: any PasswordCredentialStore = CredentialStores.passwords(),
        reconnect: ReconnectPolicy = ReconnectPolicy()
    ) {
        self.reconnect = reconnect
        let scheme = url.scheme?.lowercased() ?? "ftp"
        let host = url.host ?? ""
        self.scheme = scheme; self.host = host
        port = url.port
        let user = url.user
        // Read a complete credential pair before publication; later updates/readers use one locked snapshot.
        let password =
            url.password(percentEncoded: false)
            ?? user.flatMap { credentialStore.password(server: host, account: $0, scheme: scheme) }
        login = FTPLoginState(user: user, password: password)
        self.curl = curl
        self.credentialStore = credentialStore
    }

    func rootTitle(_ url: URL) -> String { login.snapshot.user.map { "\($0)@\(host)" } ?? host }

    /// ftps:// is FTP with required TLS (`--ssl-reqd`), so curl gets ftp:// either way.
    private func base(_ path: String) -> String {
        var s = "ftp://\(host)"
        if let p = port { s += ":\(p)" }
        return s + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    /// curl URLs are relative to the login folder, so raw FTP commands must be too. Line breaks would
    /// smuggle extra commands onto the control connection, so they are refused.
    private func rel(_ u: URL) throws -> String {
        guard !RemoteFS.hasLineBreak(u.path) else { throw RemoteError.invalidName(u.lastPathComponent) }
        let p = String(u.path.drop(while: { $0 == "/" }))
        return p.isEmpty ? "." : p
    }

    /// curl config with the login, in curl's quoted-string syntax.
    private var credentials: Data? {
        let current = login.snapshot
        guard let user = current.user else { return nil }
        return Data("user = \"\(Self.configEscaped("\(user):\(current.password ?? "")"))\"\n".utf8)
    }

    /// curl config quoted-string escaping, by code point: a quote followed by a combining mark is one Character,
    /// which a Character-based replace would leave unescaped, ending the string early.
    static func configEscaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// curl's failure when the connection was lost, carried through the reconnection tries.
    private struct Lost: Error {
        let result: Shell.Result
    }

    /// Runs curl; on a login failure asks for credentials once (and keeps them in the Keychain). Each run is a new
    /// connection, so after a lost one (sleep, a network change) curl runs again, if the server was reached before:
    /// any `idempotent` command, the others only when curl never connected.
    @discardableResult
    private func curlRun(_ args: [String], stdoutFile: URL? = nil, retry: Bool = true, idempotent: Bool = true) throws -> Data {
        let login = credentials
        // --globoff: a local file named "report[1].pdf" or "{a,b}" is a name, not a pattern (URLs are percent-encoded).
        var all = ["-s", "-S", "--globoff", "--connect-timeout", String(Self.connectTimeout)]
        if args.contains("-T"), let limit = Shell.currentTransferControl?.bytesPerSecond, limit > 0 {
            // curl opens upload files itself (stdin carries credentials), so it owns this leg's pacing.
            all += ["--limit-rate", String(limit)]
        }
        if scheme == "ftps" { all += ["--ssl-reqd"] }
        if login != nil { all += ["--config", "-"] }
        let r: Shell.Result
        do {
            let policy = Shell.currentTransferControl?.managesRetries == true ? ReconnectPolicy.never : reconnect
            r = try policy.run(
                connectedBefore: { connected },
                isLoss: { ($0 as? Lost).map { idempotent || ReconnectPolicy.isConnectFailure(curlStatus: $0.result.status) } ?? false },
                wait: wait
            ) {
                let r = try Shell.run(curl, all + args, stdin: login, stdoutFile: stdoutFile)
                if ReconnectPolicy.isConnectionLoss(curlStatus: r.status) { throw Lost(result: r) }
                connected = true
                return r
            }
        } catch let lost as Lost {
            r = lost.result
        }
        if r.status == Self.loginDenied || r.err.contains("530"), retry, askCredentials() {
            return try curlRun(args, stdoutFile: stdoutFile, retry: false, idempotent: idempotent)
        }
        if r.status != 0 {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if ReconnectPolicy.isConnectionLoss(curlStatus: r.status) {
                throw TransferConnectionError(message: msg.isEmpty ? "Waiting for network" : msg)
            }
            throw RemoteError.failed(msg.isEmpty ? "FTP error \(r.status)" : msg)
        }
        return r.out
    }

    /// Raw FTP commands (`-Q`); the listing curl fetches afterwards is discarded.
    private func command(_ commands: String...) throws {
        try curlRun(commands.flatMap { ["-Q", $0] } + ["-o", "/dev/null", base("/")], idempotent: false)
    }

    private func askCredentials() -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { askCredentialsOnMain() } }
        return DispatchQueue.main.sync { askCredentialsOnMain() }
    }

    @MainActor private func askCredentialsOnMain() -> Bool {
        guard let answer = RemoteFS.askLogin(host, login.snapshot.user) else { return false }
        login.replace(user: answer.user, password: answer.password)
        credentialStore.save(server: host, account: answer.user, password: answer.password, scheme: scheme)
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
        var above: Set<String> = []
        try upload(local, into: remoteFolder, above: &above)
    }

    /// `above`: the real paths of the folders being uploaded around `local`. Links to folders are followed, but
    /// not into one of those: a "link -> .." inside would recurse until the path is too long.
    private func upload(_ local: URL, into remoteFolder: URL, above: inout Set<String>) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        let target = remoteFolder.appendingPathComponent(local.lastPathComponent)
        if isDir.boolValue {
            let real = local.resolvingSymlinksInPath().path
            guard above.insert(real).inserted else { return }
            defer { above.remove(real) }
            try makeFolder(target)
            for c in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(c, into: target, above: &above)
            }
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

    func removeEmptyFolder(_ remote: URL) throws { try command("RMD \(try rel(remote))") }

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

extension FTPProvider: RemoteTransferPublishing {
    public func publishTransferFile(_ staged: URL, to target: URL, modified: Date?) throws {
        if let modified {
            // MFMT is optional in FTP: failure leaves the existing target intact. Content mode needs no MFMT.
            try command("MFMT \(FileFormat.posixString(modified, format: "yyyyMMddHHmmss", timeZone: .gmt)) \(try rel(staged))")
        }
        // RNTO replaces a file atomically on supporting servers; otherwise fail without a delete fallback.
        try command("RNFR \(try rel(staged))", "RNTO \(try rel(target))")
    }
}

extension FTPProvider: RemoteTransferMetadata {
    public func transferModificationDate(_ remote: URL) throws -> Date {
        let headers = String(decoding: try curlRun(["--head", base(remote.path)]), as: UTF8.self)
        for line in headers.components(separatedBy: "\n") where line.lowercased().hasPrefix("last-modified:") {
            if let date = FileFormat.posixDate(
                String(line.dropFirst("Last-Modified:".count)).trimmingCharacters(in: .whitespacesAndNewlines),
                format: "EEE, dd MMM yyyy HH:mm:ss zzz", timeZone: .gmt)
            {
                return date
            }
        }
        throw FileOperationError.failed("This FTP server does not provide precise modification dates. Choose Content or Size comparison.")
    }
}
