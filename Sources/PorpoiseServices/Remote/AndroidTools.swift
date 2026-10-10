import Foundation

/// Android support needs Google's `adb`. Google's licence doesn't allow shipping it inside Porpoise, so Porpoise
/// downloads the official platform-tools from Google on request, into its own Application Support folder.
public enum AndroidTools {
    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    static var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/platform-tools", isDirectory: true)
    }

    /// Porpoise's own copy first, then one installed elsewhere (Homebrew, Android Studio).
    static var adbPath: String? {
        let own = installDir.appendingPathComponent("adb").path
        return FileManager.default.isExecutableFile(atPath: own) ? own : Shell.which("adb")
    }

    public static var isInstalled: Bool { adbPath != nil }

    // MARK: adb's server

    /// adb starts a server (port 5037) on first use that keeps running after adb exits. When Porpoise started it, it
    /// stops it on quit; one that was already running (Android Studio, a terminal) is left alone.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checked = false
    nonisolated(unsafe) private static var startedServer = false

    /// Call before running adb.
    static func willUseServer() {
        lock.lock(); defer { lock.unlock() }
        guard !checked else { return }
        checked = true
        startedServer = !serverIsRunning()
    }

    public static func stopServerIfOurs() {
        lock.lock(); let ours = startedServer; lock.unlock()
        guard ours, let adb = adbPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["kill-server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        // Quitting shouldn't hang on it.
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
    }

    /// Something is listening on adb's port.
    private static func serverIsRunning() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(5037).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Downloads and unpacks platform-tools; calls back on the main thread with an error message or nil.
    public static func install(done: @escaping (String?) -> Void) {
        URLSession.shared.downloadTask(with: downloadURL) { file, response, error in
            func finish(_ msg: String?) { DispatchQueue.main.async { done(msg) } }
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return finish("The download from Google failed: \(error?.localizedDescription ?? "no response").")
            }
            let fm = FileManager.default
            let parent = installDir.deletingLastPathComponent()
            let staging = parent.appendingPathComponent("platform-tools.download-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                let r = try Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path], timeout: 120)
                let unpacked = staging.appendingPathComponent("platform-tools")
                guard r.status == 0, fm.isExecutableFile(atPath: unpacked.appendingPathComponent("adb").path) else {
                    return finish("The downloaded archive could not be unpacked.")
                }
                try? fm.removeItem(at: installDir)
                try fm.moveItem(at: unpacked, to: installDir)
                finish(nil)
            } catch {
                finish(error.localizedDescription)
            }
        }.resume()
    }
}
