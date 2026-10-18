import CryptoKit
import Foundation

/// SSH host-key fingerprints, written as ssh writes them ("SHA256:" and unpadded base64), and what ssh reports when a
/// server's key is not the one known for it.
public enum HostKeyFingerprint {
    /// The fingerprint of a public key in its one-line form ("ssh-ed25519 AAAA… comment", as in a .pub file,
    /// known_hosts after the host field, or ssh-keyscan's output after the host); nil when it isn't one.
    public static func of(publicKeyLine line: String) -> String? {
        // The first line only: the word after the type must be the whole blob.
        let first = line.split(whereSeparator: \.isNewline).first ?? ""
        let words = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // The base64 blob follows the key type; a known_hosts line has the host names first.
        guard let typeIndex = words.firstIndex(where: isKeyType), typeIndex + 1 < words.count,
            let blob = Data(base64Encoded: words[typeIndex + 1])
        else { return nil }
        return of(blob: blob)
    }

    /// The fingerprint of a raw public-key blob.
    public static func of(blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func isKeyType(_ word: String) -> Bool {
        word.hasPrefix("ssh-") || word.hasPrefix("ecdsa-") || word.hasPrefix("sk-")
    }

    /// The environment variable that gives the ssh prompt helper the fingerprint the user accepted: it answers ssh's
    /// "continue connecting (yes/no/[fingerprint])?" with it, and ssh accepts only a key with that fingerprint.
    public static let answerVariable = "PORPOISE_HOSTKEY_ANSWER"

    /// The `known_hosts` name of a host: "host", or "[host]:port" when the port isn't 22.
    public static func knownHostsName(host: String, port: Int?) -> String {
        guard let port, port != 22 else { return host }
        return "[\(host)]:\(port)"
    }

    /// What ssh said when it refused a server whose key changed.
    public struct Change: Equatable, Sendable {
        /// The key type ssh names ("ED25519", "RSA", "ECDSA").
        public var keyType: String?
        /// The fingerprint of the key the server sent.
        public var fingerprint: String
        /// The known_hosts file and line that hold the old key.
        public var knownHostsFile: String?
        public var line: Int?
    }

    /// The change ssh reported in `stderr`, or nil when it reported something else.
    public static func change(inSSHError stderr: String) -> Change? {
        guard stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") else { return nil }
        let lines = stderr.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var change = Change(keyType: nil, fingerprint: "")
        for (i, l) in lines.enumerated() {
            if l.hasPrefix("The fingerprint for the "), l.hasSuffix(" key sent by the remote host is") {
                change.keyType = String(l.dropFirst("The fingerprint for the ".count).dropLast(" key sent by the remote host is".count))
                if i + 1 < lines.count { change.fingerprint = String(lines[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            } else if l.hasPrefix("Offending "), let r = l.range(of: " key in ") {
                // "Offending ED25519 key in /path/known_hosts:3"; the path may contain ":".
                let location = l[r.upperBound...]
                if let colon = location.lastIndex(of: ":"), let n = Int(location[location.index(after: colon)...]) {
                    change.knownHostsFile = String(location[..<colon])
                    change.line = n
                } else {
                    change.knownHostsFile = String(location)
                }
            }
        }
        return change.fingerprint.hasPrefix("SHA256:") ? change : nil
    }
}
