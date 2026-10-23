import Foundation
import PorpoiseCore

/// Import only non-executable presentation preferences from user config; never load global configuration into status.
struct GitUserPreferences {
    var excludes: URL?
    var untracked: String?
    static func load(
        in repository: URL, deadline: TimeInterval, home suppliedHome: URL? = nil,
        xdg: URL? = nil
    ) throws -> Self {
        let home =
            suppliedHome
            ?? (Settings.isTesting
                ? Settings.supportFolder.appendingPathComponent("GitPreferences") : FileManager.default.homeDirectoryForCurrentUser)
        let userXDG = Settings.isTesting ? nil : ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let xdg = xdg ?? userXDG.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(".config")
        var values: [String: String] = [:]
        for config in [xdg.appendingPathComponent("git/config"), home.appendingPathComponent(".gitconfig")] {
            guard regularLocalFile(config) else { continue }
            let data = try GitCommand.run(["config", "--null", "--list", "--includes", "--file", config.path], in: repository, deadline: deadline)
            for (key, value) in pairs(data) where ["core.excludesfile", "status.showuntrackedfiles"].contains(key) { values[key] = value }
        }
        let ignore: URL
        if let path = values["core.excludesfile"] {
            if path.hasPrefix("~/") {
                ignore = home.appendingPathComponent(String(path.dropFirst(2)))
            } else if path.hasPrefix("/") {
                ignore = URL(fileURLWithPath: path)
            } else {
                ignore = repository.appendingPathComponent(path)
            }
        } else {
            ignore = xdg.appendingPathComponent("git/ignore")
        }
        return Self(excludes: regularLocalFile(ignore) ? ignore : nil, untracked: values["status.showuntrackedfiles"])
    }
    static func regularLocalFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .volumeIsLocalKey]) else { return false }
        return values.isRegularFile == true && values.volumeIsLocal == true && FileManager.default.isReadableFile(atPath: url.path)
    }
    static func pairs(_ data: Data) -> [(String, String)] {
        data.split(separator: 0).compactMap { bytes in
            guard let record = String(data: Data(bytes), encoding: .utf8), let newline = record.firstIndex(of: "\n") else { return nil }
            return (String(record[..<newline]), String(record[record.index(after: newline)...]))
        }
    }
    /// Repository values beat the safely imported global preference. Required filters become optional, but the
    /// sandbox still forbids executing them; Git conservatively treats a file needing a filter as modified.
    func configuration(in repository: URL, deadline: TimeInterval) throws -> [String] {
        let data = try GitCommand.run(["config", "--null", "--list", "--includes"], in: repository, deadline: deadline)
        let pairs = Self.pairs(data)
        let mode = pairs.last { $0.0 == "status.showuntrackedfiles" }?.1 ?? untracked ?? "normal"
        var result = ["status.showUntrackedFiles=" + (["no", "normal", "all"].contains(mode) ? mode : "normal")]
        if let excludes { result.append("core.excludesFile=" + excludes.path) }
        for (key, _) in pairs where key.hasPrefix("filter.") && key.hasSuffix(".required") { result.append(key + "=false") }
        return result
    }
}
