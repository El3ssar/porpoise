import CryptoKit
import Foundation

public enum ChecksumAlgorithm: String, CaseIterable, Codable, Sendable {
    case sha256, sha512, md5, sha1
    public var title: String {
        switch self {
        case .sha256: return "SHA-256";
        case .sha512: return "SHA-512";
        case .md5: return "MD5 (legacy)";
        case .sha1: return "SHA-1 (legacy)"
        }
    }
    public var digits: Int {
        switch self {
        case .sha256: return 64;
        case .sha512: return 128;
        case .md5: return 32;
        case .sha1: return 40
        }
    }
    public func accepts(_ digest: String) -> Bool {
        digest.count == digits && digest.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

public enum ChecksumHasher {
    case sha256(SHA256), sha512(SHA512), md5(Insecure.MD5), sha1(Insecure.SHA1)
    public init(_ algorithm: ChecksumAlgorithm) {
        switch algorithm {
        case .sha256: self = .sha256(SHA256());
        case .sha512: self = .sha512(SHA512());
        case .md5: self = .md5(Insecure.MD5());
        case .sha1: self = .sha1(Insecure.SHA1())
        }
    }
    public mutating func update(_ data: Data) {
        switch self {
        case .sha256(var h): h.update(data: data); self = .sha256(h)
        case .sha512(var h): h.update(data: data); self = .sha512(h)
        case .md5(var h): h.update(data: data); self = .md5(h)
        case .sha1(var h): h.update(data: data); self = .sha1(h)
        }
    }
    public func finalize() -> String {
        let bytes: [UInt8]
        switch self {
        case .sha256(let h): bytes = Array(h.finalize());
        case .sha512(let h): bytes = Array(h.finalize());
        case .md5(let h): bytes = Array(h.finalize());
        case .sha1(let h): bytes = Array(h.finalize())
        }
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
    }
}

public struct ChecksumEntry: Equatable, Sendable {
    public var path: String
    public var algorithm: ChecksumAlgorithm
    public var digest: String
    public init(path: String, algorithm: ChecksumAlgorithm, digest: String) {
        self.path = path; self.algorithm = algorithm; self.digest = digest.lowercased()
    }
}
public enum ChecksumManifest {
    public struct Invalid: Error, LocalizedError {
        public let line: Int
        public let reason: String
        public init(line: Int, reason: String) { self.line = line; self.reason = reason }
        /// Line 0: not about a line of a manifest (a path, where to save).
        public var errorDescription: String? { line > 0 ? "Manifest line \(line): \(reason)" : reason.prefix(1).uppercased() + reason.dropFirst() }
    }
    public static func parse(_ text: String) throws -> [ChecksumEntry] {
        var entries: [ChecksumEntry] = []
        let bsd = try! NSRegularExpression(
            pattern: "^(MD5|SHA1|SHA256|SHA512|SHA-1|SHA-256|SHA-512) \\((.*)\\) = ([a-fA-F0-9]+)$", options: .caseInsensitive)
        for (i, source) in text.components(separatedBy: "\n").enumerated() {
            let line = source.hasSuffix("\r") ? String(source.dropLast()) : source
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let number = i + 1
            if let match = bsd.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let parts = (1...3).map { String(line[Range(match.range(at: $0), in: line)!]) }
                guard let algorithm = ChecksumAlgorithm(rawValue: parts[0].lowercased().replacingOccurrences(of: "-", with: "")),
                    algorithm.accepts(parts[2]), !parts[1].isEmpty
                else { throw Invalid(line: number, reason: "invalid checksum") }
                entries.append(ChecksumEntry(path: parts[1], algorithm: algorithm, digest: parts[2])); continue
            }
            let escaped = line.hasPrefix("\\"), raw = escaped ? String(line.dropFirst()) : line
            guard let space = raw.firstIndex(of: " ") else { throw Invalid(line: number, reason: "expected GNU or BSD checksum record") }
            let digest = String(raw[..<space]), marker = raw.index(after: space)
            guard marker < raw.endIndex, raw[marker] == " " || raw[marker] == "*",
                let algorithm = ChecksumAlgorithm.allCases.first(where: { $0.accepts(digest) })
            else { throw Invalid(line: number, reason: "invalid checksum or separator") }
            var name = String(raw[raw.index(after: marker)...])
            if escaped {
                var decoded = "", escape = false
                for c in name {
                    if escape {
                        switch c {
                        case "n": decoded.append("\n");
                        case "r": decoded.append("\r");
                        case "\\": decoded.append("\\");
                        default: throw Invalid(line: number, reason: "unknown filename escape")
                        }
                        escape = false
                    } else if c == "\\" {
                        escape = true
                    } else {
                        decoded.append(c)
                    }
                }
                guard !escape else { throw Invalid(line: number, reason: "incomplete filename escape") }; name = decoded
            }
            guard !name.isEmpty else { throw Invalid(line: number, reason: "empty filename") }
            entries.append(ChecksumEntry(path: name, algorithm: algorithm, digest: digest))
        }
        guard !entries.isEmpty else { throw Invalid(line: 1, reason: "no checksums found") }
        return entries
    }
    public static func export(_ entries: [ChecksumEntry]) -> String {
        entries.map { entry in
            let escaped = entry.path.contains("\n") || entry.path.contains("\r") || entry.path.contains("\\")
            let path =
                escaped
                ? entry.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(
                    of: "\r", with: "\\r") : entry.path
            return (escaped ? "\\" : "") + entry.digest + "  " + path
        }.joined(separator: "\n") + "\n"
    }
    public static func resolve(_ entry: ChecksumEntry, below root: URL) throws -> URL {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.path.hasPrefix("/"), !components.contains(".."), !entry.path.contains("\0") else {
            throw Invalid(line: 0, reason: "path escapes manifest folder")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(entry.path).standardizedFileURL
        guard FilePath.contains(path: url.resolvingSymlinksInPath().path, in: base.path) else {
            throw Invalid(line: 0, reason: "symlink escapes manifest folder")
        }
        return url
    }
}
