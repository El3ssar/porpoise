import Foundation
import PorpoiseCore
import Security

/// FTP through curl. Credentials reach curl on stdin (`--config -`), never on its command line, where
/// any local user could read them with `ps`.
final class FTPProvider: RemoteProvider {
    private let scheme: String
    private let host: String
    private let port: Int?
    private var user: String?
    private var password: String?
    private let curl: String
    /// Where logins are looked up and saved (nil: the user's keychains).
    private let keychain: SecKeychain?

    /// curl's exit code for a refused login (CURLE_LOGIN_DENIED).
    private static let loginDenied: Int32 = 67
    private static let connectTimeout = 15

    /// Tests pass their own `curl` (which records what it gets) and a throwaway keychain.
    init(url: URL, curl: String = "/usr/bin/curl", keychain: SecKeychain? = nil) {
        scheme = url.scheme?.lowercased() ?? "ftp"
        host = url.host ?? ""
        port = url.port
        user = url.user
        // `password` alone stays percent-encoded ("p%40ss"); the server needs the password itself.
        password = url.password(percentEncoded: false)
        self.curl = curl
        self.keychain = keychain
        if let u = user, password == nil { password = Keychain.password(server: host, account: u, scheme: scheme, in: keychain) }
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
        guard !RemoteFS.hasLineBreak(u.path) else { throw RemoteError.invalidName(u.lastPathComponent) }
        let p = String(u.path.drop(while: { $0 == "/" }))
        return p.isEmpty ? "." : p
    }

    /// curl config with the login, in curl's quoted-string syntax.
    private var credentials: Data? {
        guard let u = user else { return nil }
        return Data("user = \"\(Self.configEscaped("\(u):\(password ?? "")"))\"\n".utf8)
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

    /// Runs curl; on a login failure asks for credentials once (and keeps them in the Keychain).
    @discardableResult
    private func curlRun(_ args: [String], stdoutFile: URL? = nil, retry: Bool = true) throws -> Data {
        let login = credentials
        // --globoff: a local file named "report[1].pdf" or "{a,b}" is a name, not a pattern (URLs are percent-encoded).
        var all = ["-s", "-S", "--globoff", "--connect-timeout", String(Self.connectTimeout)]
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
        guard let login = RemoteFS.askLogin(host, user) else { return false }
        user = login.user
        password = login.password
        Keychain.save(server: host, account: login.user, password: login.password, scheme: scheme, in: keychain)
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

extension FTPProvider: SyncRemotePublishing {
    public func publishSyncFile(_ staged: URL, to target: URL, modified: Date?) throws {
        if let modified {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
            // MFMT is optional in FTP: failure leaves the existing target intact. Content mode needs no MFMT.
            try command("MFMT \(formatter.string(from: modified)) \(try rel(staged))")
        }
        // RNTO replaces a file atomically on supporting servers; otherwise fail without a delete fallback.
        try command("RNFR \(try rel(staged))", "RNTO \(try rel(target))")
    }
}

extension FTPProvider: SyncRemoteMetadata {
    public func syncModificationDate(_ remote: URL) throws -> Date {
        let headers = String(decoding: try curlRun(["--head", base(remote.path)]), as: UTF8.self)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt; formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for line in headers.components(separatedBy: "\n") where line.lowercased().hasPrefix("last-modified:") {
            if let date = formatter.date(from: String(line.dropFirst("Last-Modified:".count)).trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        throw SyncEngineError.unsupported("This FTP server does not provide precise modification dates. Choose Content or Size comparison.")
    }
}
