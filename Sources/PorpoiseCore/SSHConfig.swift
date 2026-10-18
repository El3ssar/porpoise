import Foundation

/// The parts of an OpenSSH client configuration (~/.ssh/config) the connection manager shows: the hosts it names and
/// what they resolve to. ssh itself still reads the file when it connects; this only lists and describes.
///
/// As in ssh, the first value found for a keyword wins, `Host` patterns may use `*`, `?` and `!negation`, `Include`
/// pulls in other files (relative to ~/.ssh) where it stands, and `Match` blocks are skipped (their conditions need a
/// live connection to decide).
public struct SSHConfig: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        /// The `Host` patterns; empty for the options before the first `Host` line, which apply to every host.
        public var patterns: [String]
        /// Keyword (lowercased) and value, in file order; a keyword may repeat (IdentityFile).
        public var options: [(String, String)]

        public static func == (a: Block, b: Block) -> Bool {
            a.patterns == b.patterns && a.options.map(\.0) == b.options.map(\.0) && a.options.map(\.1) == b.options.map(\.1)
        }

        /// Whether `host` is matched: by some pattern, and by none of the negated ones.
        public func matches(_ host: String) -> Bool {
            if patterns.isEmpty { return true }
            let h = host.lowercased()
            var hit = false
            for p in patterns {
                if p.hasPrefix("!") {
                    if SSHConfig.glob(String(p.dropFirst()).lowercased(), h) { return false }
                } else if SSHConfig.glob(p.lowercased(), h) {
                    hit = true
                }
            }
            return hit
        }
    }

    /// What one host resolves to.
    public struct Host: Equatable, Sendable {
        /// The name written after `Host`, which is what `ssh <alias>` takes.
        public var alias: String
        public var hostName: String
        public var user: String?
        public var port: Int?
        /// The jump hosts, outermost first (`ProxyJump a,b`); empty for a direct connection.
        public var proxyJump: [String]
        public var identityFiles: [String]
        /// A `ProxyCommand` other than `none`: ssh reaches the host through a command we don't describe.
        public var proxyCommand: String?
    }

    public var blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// Reads `text`; `include` returns the text of the files an `Include` names (already expanded), in order.
    public init(parsing text: String, include: (String) -> [String] = { _ in [] }, depth: Int = 0) {
        var blocks = [Block(patterns: [], options: [])]
        for raw in text.components(separatedBy: .newlines) {
            guard let (key, value) = Self.split(raw) else { continue }
            switch key {
            case "host":
                blocks.append(Block(patterns: Self.words(value), options: []))
            case "match":
                // Never matched: an impossible pattern keeps the block's options out of every host.
                blocks.append(Block(patterns: ["!*"], options: []))
            case "include" where depth < 16:
                // Included files' options belong to the block the Include stands in, until they start their own.
                for path in Self.words(value) {
                    for t in include(path) {
                        let inner = SSHConfig(parsing: t, include: include, depth: depth + 1).blocks
                        guard let first = inner.first else { continue }
                        blocks[blocks.count - 1].options += first.options
                        blocks += inner.dropFirst()
                    }
                }
            default:
                blocks[blocks.count - 1].options.append((key, value))
            }
        }
        self.blocks = blocks
    }

    /// Reads ~/.ssh/config (or `url`), following its Includes.
    public static func load(_ url: URL = defaultURL) -> SSHConfig {
        let dir = url.deletingLastPathComponent()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return SSHConfig(blocks: []) }
        return SSHConfig(parsing: text) { path in includedFiles(path, sshDir: dir).compactMap { try? String(contentsOf: $0, encoding: .utf8) } }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// The files an `Include` path names: `~` is the home folder, a relative path is in ~/.ssh, and the last
    /// component may be a wildcard (files in name order, as ssh's glob gives them).
    static func includedFiles(_ path: String, sshDir: URL) -> [URL] {
        let full: URL
        if path.hasPrefix("~/") {
            full = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            full = URL(fileURLWithPath: path)
        } else {
            full = sshDir.appendingPathComponent(path)
        }
        let name = full.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [full] }
        let folder = full.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { glob(name, $0) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// The names written after `Host` that are a host of their own (no wildcard or negation), in file order.
    public var aliases: [String] {
        var seen = Set<String>()
        return blocks.flatMap(\.patterns).filter { p in
            !p.contains("*") && !p.contains("?") && !p.hasPrefix("!") && seen.insert(p.lowercased()).inserted
        }
    }

    /// Every alias, resolved.
    public var hosts: [Host] { aliases.map(resolve) }

    /// What `alias` resolves to: the first value of each keyword among the blocks that match it.
    public func resolve(_ alias: String) -> Host {
        var first: [String: String] = [:]
        var identities: [String] = []
        for b in blocks where b.matches(alias) {
            for (k, v) in b.options {
                if k == "identityfile" { identities.append(v) } else if first[k] == nil { first[k] = v }
            }
        }
        let hostName = first["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
        let jumps = first["proxyjump"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        let command = first["proxycommand"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        return Host(
            alias: alias, hostName: hostName, user: first["user"], port: first["port"].flatMap(Int.init),
            proxyJump: jumps.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? [],
            identityFiles: identities, proxyCommand: command)
    }

    /// Keyword (lowercased) and value of one line; nil for blank lines and comments. "Key value", "Key=value" and
    /// "Key = value" are all accepted.
    static func split(_ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        guard let end = t.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (t.lowercased(), "") }
        var rest = t[end...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return (t[..<end].lowercased(), String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// Whitespace-separated words; a double-quoted word may hold spaces.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var started = false
        for ch in s {
            if ch == "\"" {
                quoted.toggle(); started = true
            } else if (ch == " " || ch == "\t") && !quoted {
                if started { out.append(cur) }
                cur = ""; started = false
            } else {
                cur.append(ch); started = true
            }
        }
        if started { out.append(cur) }
        return out
    }

    /// ssh's pattern match: `*` any run of characters, `?` one character, everything else literal.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
