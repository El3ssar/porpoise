import AppKit
import PorpoiseCore

/// A remote file system reachable through a command-line tool (Dolphin's KIO workers, the Mac way).
protocol RemoteProvider: AnyObject {
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
enum RemoteFS {
    static let sshSchemes: Set<String> = ["sftp", "ssh", "fish", "scp"]
    static let ftpSchemes: Set<String> = ["ftp", "ftps"]
    static let mountSchemes: Set<String> = ["smb", "afp", "nfs", "webdav", "webdavs", "dav", "davs", "cifs", "vnc"]

    static func isRemote(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return sshSchemes.contains(s) || ftpSchemes.contains(s) || s == "adb"
    }

    private static var providers: [String: RemoteProvider] = [:]
    private static let lock = NSLock()

    /// One provider (connection) per scheme+user+host+port.
    /// Closes shared ssh connections (ControlMaster) when the app quits, instead of leaving them up for minutes.
    static func disconnectAll() {
        lock.lock()
        let all = Array(providers.values)
        lock.unlock()
        for p in all { (p as? SSHProvider)?.disconnect() }
    }

    static func provider(for url: URL) -> RemoteProvider? {
        guard let s = url.scheme?.lowercased(), isRemote(url) else { return nil }
        let key = "\(s)://\(url.user ?? "")@\(url.host ?? "")#\(url.port ?? 0)"
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
    static func parseTyped(_ text: String) -> URL? {
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

    /// Local cache for files opened from remote locations.
    static var cacheRoot: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise/remote")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func displayName(for url: URL) -> String {
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
        let staging = folder.appendingPathComponent(".dolphin-download-\(UUID().uuidString)")
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

// MARK: - Process helper

enum Shell {
    struct Result { var status: Int32; var out: Data; var err: String }

    /// Grace period between SIGTERM and SIGKILL when a timeout expires.
    private static let killGrace: TimeInterval = 2

    /// Runs a tool synchronously (call off the main thread). `stdinFile`/`stdoutFile` stream large data.
    /// stdin is written and stdout/stderr are drained concurrently, so neither side can block on a full
    /// pipe. With `timeout` > 0 the tool is terminated (then killed) when it runs longer, and the call throws.
    @discardableResult
    static func run(_ tool: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil,
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
        DispatchQueue.global().async(group: io) { box.err = errPipe.fileHandleForReading.readDataToEndOfFile() }
        if stdoutFile == nil {
            DispatchQueue.global().async(group: io) { box.out = outPipe.fileHandleForReading.readDataToEndOfFile() }
        }
        if let data = stdin, let w = inPipe?.fileHandleForWriting {
            DispatchQueue.global().async(group: io) {
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

// MARK: - Password prompt for ssh (SSH_ASKPASS) and FTP

/// Native password / confirmation prompt. ssh calls our own binary with `--askpass "<prompt>"`.
enum AskPass {
    /// Path of a tiny script ssh can execute as SSH_ASKPASS (it calls back into the app binary).
    static let scriptPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("askpass.sh")
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Single-quoted, so an install path with quotes, `$` or backticks stays a plain path.
        let body = "#!/bin/sh\nexec \(RemoteParsing.quote(exe)) --askpass \"$1\"\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        return script.path
    }()

    /// Runs in the helper process: shows a dialog, prints the answer, exits.
    static func runHelper(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let a = NSAlert()
        let isConfirm = prompt.lowercased().contains("yes/no") || prompt.lowercased().contains("continue connecting")
        a.messageText = isConfirm ? "Connect to this server?" : "Authentication Required"
        a.informativeText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        a.addButton(withTitle: isConfirm ? "Connect" : "OK")
        a.addButton(withTitle: "Cancel")
        var field: NSSecureTextField?
        if !isConfirm {
            let f = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
            a.accessoryView = f
            a.window.initialFirstResponder = f
            field = f
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { exit(1) }
        print(isConfirm ? "yes" : (field?.stringValue ?? ""))
        exit(0)
    }
}
