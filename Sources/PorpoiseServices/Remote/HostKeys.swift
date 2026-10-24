import Foundation
import PorpoiseCore

/// What this Mac knows about SSH servers' keys, through OpenSSH's own tools: the effective settings for a host
/// (`ssh -G`, which reads ~/.ssh/config without connecting), the fingerprints recorded in known_hosts
/// (`ssh-keygen -F`), and removing a key the user replaced after seeing the new one's fingerprint.
public enum HostKeys {
    static let ssh = "/usr/bin/ssh"
    static let keygen = "/usr/bin/ssh-keygen"
    static let sshAdd = "/usr/bin/ssh-add"

    /// The settings ssh would use for `host` (an address or a ~/.ssh/config alias): keyword (lowercased) to values.
    public struct Effective: Equatable, Sendable {
        public var values: [String: [String]]
        public init(values: [String: [String]]) { self.values = values }
        public func first(_ key: String) -> String? { values[key]?.first }
        public var hostName: String? { first("hostname") }
        public var user: String? { first("user") }
        public var port: Int? { first("port").flatMap(Int.init) }
        public var proxyJump: [String] {
            guard let j = first("proxyjump"), j.lowercased() != "none" else { return [] }
            return j.split(separator: ",").map(String.init)
        }
        /// The known_hosts files ssh reads, with `~` expanded.
        public var knownHostsFiles: [String] {
            (values["userknownhostsfile"] ?? []).flatMap { $0.split(separator: " ").map { ($0 as NSString).expandingTildeInPath } }
        }
        /// The name the host's key is recorded under: HostKeyAlias, or the host name with a port other than 22.
        public var knownHostsName: String? {
            if let alias = first("hostkeyalias"), alias.lowercased() != "none" { return alias }
            return hostName.map { HostKeyFingerprint.knownHostsName(host: $0, port: port) }
        }

        static func parse(_ text: String) -> Effective {
            var values: [String: [String]] = [:]
            for line in text.split(separator: "\n") {
                guard let space = line.firstIndex(of: " ") else { continue }
                values[line[..<space].lowercased(), default: []].append(String(line[line.index(after: space)...]))
            }
            return Effective(values: values)
        }
    }

    /// `ssh -G` for `host` with `options` first (a profile's or a test's); nil when ssh can't resolve the settings.
    public static func effective(host: String, user: String? = nil, port: Int? = nil, options: [String] = []) -> Effective? {
        guard !host.hasPrefix("-") else { return nil }
        var args = options + ["-G"]
        if let port { args += ["-p", String(port)] }
        if let user, !user.isEmpty, !user.hasPrefix("-") { args += ["-l", user] }
        guard let r = try? Shell.run(ssh, args + ["--", host], timeout: 5), r.status == 0 else { return nil }
        return Effective.parse(String(decoding: r.out, as: UTF8.self))
    }

    /// A key recorded for a host.
    public struct Known: Equatable, Sendable {
        /// "ED25519", "RSA", "ECDSA".
        public var type: String
        public var fingerprint: String
        public var file: String
    }

    /// The keys known_hosts `files` hold for `name` ("host" or "[host]:port"), hashed entries included.
    public static func known(name: String, in files: [String]) -> [Known] {
        files.flatMap { file -> [Known] in
            guard FileManager.default.fileExists(atPath: file),
                let r = try? Shell.run(keygen, ["-l", "-F", name, "-f", file], timeout: 5), r.status == 0
            else { return [] }
            return parseListing(String(decoding: r.out, as: UTF8.self), file: file)
        }
    }

    /// `ssh-keygen -l -F` output: "# Host … found: line 1" comments, then "name ED25519 SHA256:…" (older versions:
    /// "256 SHA256:… name (ED25519)").
    static func parseListing(_ text: String, file: String) -> [Known] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let words = line.split(separator: " ")
            guard let i = words.firstIndex(where: { $0.hasPrefix("SHA256:") }) else { return nil }
            let type: Substring
            if let last = words.last, last.hasPrefix("("), last.hasSuffix(")") {
                type = last.dropFirst().dropLast()
            } else {
                type = i > 0 ? words[i - 1] : ""
            }
            return Known(type: String(type), fingerprint: String(words[i]), file: file)
        }
    }

    /// The known keys of a server ssh reaches as `host` (with `options` first), for the Connections window.
    public static func known(host: String, user: String? = nil, port: Int? = nil, options: [String] = []) -> [Known] {
        guard let e = effective(host: host, user: user, port: port, options: options), let name = e.knownHostsName else { return [] }
        return known(name: name, in: e.knownHostsFiles)
    }

    /// Removes `name`'s keys from the known_hosts `file`, after the user accepted the server's new key. ssh-keygen
    /// keeps the old file as `file.old`.
    static func remove(name: String, from file: String) throws {
        let r = try Shell.run(keygen, ["-R", name, "-f", file], timeout: 5)
        guard r.status == 0 else { throw RemoteError.failed("Could not remove the old key of \(name): \(r.err)") }
    }

    /// Approve a changed key in isolation. A failed command never removes established trust.
    static func replacing(
        name: String, in file: String, fingerprint: String, approve: (String) throws -> Shell.Result
    ) throws -> Shell.Result {
        let original = URL(fileURLWithPath: file)
        let before = try Data(contentsOf: original)
        let temporary = original.deletingLastPathComponent().appendingPathComponent(".porpoise-known-hosts-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: original, to: temporary)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(atPath: temporary.path + ".old")
        }
        try remove(name: name, from: temporary.path)
        let result = try approve(temporary.path)
        guard result.status == 0 else { return result }
        guard known(name: name, in: [temporary.path]).contains(where: { $0.fingerprint == fingerprint }),
            try Data(contentsOf: original) == before
        else { throw RemoteError.failed("The saved host keys changed during approval. Connect again to review them.") }
        try Data(contentsOf: temporary).write(to: original, options: .atomic)
        return result
    }

    /// The ssh agent the app's ssh uses, and how many keys it holds.
    public enum Agent: Equatable, Sendable {
        case keys(Int)
        case empty
        case unavailable
    }

    public static func agent(environment: [String: String] = agentEnvironment()) -> Agent {
        guard let r = try? Shell.run(sshAdd, ["-l"], env: environment, timeout: 5) else { return .unavailable }
        switch r.status {
        case 0: return .keys(String(decoding: r.out, as: UTF8.self).split(separator: "\n").count)
        case 1: return .empty
        default: return .unavailable
        }
    }

    /// The agent's socket for ssh: the app's own environment's, or launchd's (the agent macOS starts for the user) when
    /// the app was started without one.
    public static func agentEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment, launchd: () -> String? = launchdAgentSocket
    ) -> [String: String] {
        if let s = env["SSH_AUTH_SOCK"], !s.isEmpty { return [:] }
        guard let s = launchd(), !s.isEmpty else { return [:] }
        return ["SSH_AUTH_SOCK": s]
    }

    private static let launchdSocket: String? = {
        guard let r = try? Shell.run("/bin/launchctl", ["getenv", "SSH_AUTH_SOCK"], timeout: 3), r.status == 0 else { return nil }
        return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    public static func launchdAgentSocket() -> String? { launchdSocket }
}
