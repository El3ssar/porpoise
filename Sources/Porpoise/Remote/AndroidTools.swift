import Foundation

/// Android support needs Google's `adb`. Google's licence doesn't allow shipping it inside Porpoise, so Porpoise
/// downloads the official platform-tools from Google on request, into its own Application Support folder.
enum AndroidTools {
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

    static var isInstalled: Bool { adbPath != nil }

    /// Downloads and unpacks platform-tools; calls back on the main thread with an error message or nil.
    static func install(done: @escaping (String?) -> Void) {
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
