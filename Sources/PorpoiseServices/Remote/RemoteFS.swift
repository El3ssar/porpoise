import Foundation
import PorpoiseCore

/// A remote file system reachable through a command-line tool (Dolphin's KIO workers, the Mac way).
public protocol RemoteProvider: AnyObject {
    func list(_ folder: URL) throws -> [FileItem]
    /// Copies a remote file or folder into a local folder; returns the local URL. Fails rather than
    /// overwrite an existing local item.
    func download(_ remote: URL, into localFolder: URL) throws -> URL
    /// Copies a local file or folder into a remote folder (replacing an item of the same name).
    func upload(_ local: URL, into remoteFolder: URL) throws
    func delete(_ remote: [URL]) throws
    func makeFolder(_ remote: URL) throws
    /// Fails if `newName` exists.
    func rename(_ remote: URL, to newName: String) throws
    /// Moves/copies within the same remote host.
    func move(_ remote: [URL], into folder: URL) throws
    func copy(_ remote: [URL], into folder: URL) throws
    /// Shown in breadcrumbs/titles for the root.
    func rootTitle(_ url: URL) -> String
}

enum RemoteError: LocalizedError {
    case failed(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        case .unsupported(let s): return s
        }
    }

    static func invalidName(_ name: String) -> RemoteError { .failed("“\(name)” is not a valid name.") }
    static func exists(_ name: String) -> RemoteError { .failed("A file named “\(name)” already exists.") }
}

/// Registry: which URL schemes are browsed through a provider.
public enum RemoteFS {
    static let sshSchemes: Set<String> = ["sftp", "ssh", "fish", "scp"]
    static let ftpSchemes: Set<String> = ["ftp", "ftps"]
    static let mountSchemes: Set<String> = ["smb", "afp", "nfs", "webdav", "webdavs", "dav", "davs", "cifs", "vnc"]

    public static func isRemote(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return sshSchemes.contains(s) || ftpSchemes.contains(s) || s == "adb"
    }

    private static var providers: [String: RemoteProvider] = [:]
    private static let lock = NSLock()

    private static func key(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.user ?? "")@\(url.host ?? "")#\(url.port ?? 0)"
    }

    /// Makes `url`'s host use `provider` (nil: a new one on next use). For tests, which connect their own way.
    static func use(_ provider: RemoteProvider?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        providers[key(url)] = provider
    }

    /// One provider (connection) per scheme+user+host+port.
    /// Closes shared ssh connections (ControlMaster) when the app quits, instead of leaving them up for minutes.
    public static func disconnectAll() {
        lock.lock()
        let all = Array(providers.values)
        lock.unlock()
        for p in all { (p as? SSHProvider)?.disconnect() }
    }

    public static func provider(for url: URL) -> RemoteProvider? {
        guard let s = url.scheme?.lowercased(), isRemote(url) else { return nil }
        let key = Self.key(url)
        lock.lock(); defer { lock.unlock() }
        if let p = providers[key] { return p }
        let p: RemoteProvider
        if sshSchemes.contains(s) { p = SSHProvider(url: url) }
        else if ftpSchemes.contains(s) { p = FTPProvider(url: url) }
        else {
            // Network adb serials are "host:port", which a URL splits into host and port.
            let host = url.host ?? ""
            p = ADBProvider(serial: url.port.map { "\(host):\($0)" } ?? host)
        }
        providers[key] = p
        return p
    }

    /// Normalizes what users type: "user@host:/path" → sftp://user@host/path, "host:path" → sftp.
    public static func parseTyped(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("://") {
            var s = t
            if s.hasPrefix("fish://") || s.hasPrefix("ssh://") || s.hasPrefix("scp://") {
                s = "sftp://" + s.components(separatedBy: "://").dropFirst().joined(separator: "://")
            }
            return URL(string: s.replacingOccurrences(of: " ", with: "%20"))
        }
        // scp-style "user@host:path"
        if let colon = t.firstIndex(of: ":"), !t.hasPrefix("/"), !t.hasPrefix("~"), t[..<colon].contains("@") || t[..<colon].contains(".") {
            let host = String(t[..<colon])
            var path = String(t[t.index(after: colon)...])
            if !path.hasPrefix("/") { path = "/~/" + path }
            return URL(string: "sftp://\(host)\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)")
        }
        return nil
    }

    /// Asks for an FTP login on the main thread (host, the user name known so far); nil when cancelled. Set by the app.
    nonisolated(unsafe) public static var askLogin: (_ host: String, _ user: String?) -> (user: String, password: String)? = { _, _ in nil }

    /// Where the cache below lives (tests use a scratch folder).
    nonisolated(unsafe) static var cacheParent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Porpoise")

    /// Local cache for files opened from remote locations.
    static var cacheRoot: URL {
        let u = cacheParent.appendingPathComponent("remote")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static func displayName(for url: URL) -> String {
        if url.path.isEmpty || url.path == "/" { return provider(for: url)?.rootTitle(url) ?? (url.host ?? "") }
        return url.lastPathComponent
    }

    /// Throws unless `name` is a single path component (no "/", not "." or ".."); also rejects line
    /// breaks, which would split FTP commands.
    static func checkName(_ name: String) throws {
        guard RemoteParsing.isSafeName(name), !name.contains("\n"), !name.contains("\r") else {
            throw RemoteError.invalidName(name)
        }
    }

    /// Downloads go to a hidden staging folder first: whatever the server sends (a tar stream may hold
    /// more than the one item asked for) stays there, and only the requested item is moved into place,
    /// never over an existing one. The staging folder is removed afterwards in every case.
    static func downloadStaged(_ name: String, into folder: URL, fetch: (URL) throws -> Void) throws -> URL {
        try checkName(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".porpoise-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try fetch(staging)
        let dst = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: dst)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
            throw RemoteError.exists(name)
        }
        return dst
    }
}
