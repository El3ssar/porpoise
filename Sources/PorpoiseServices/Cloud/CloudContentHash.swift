import CryptoKit
import Foundation

/// SHA256 of the concatenated SHA256 digests of 4 MiB blocks (empty input has zero blocks).
public enum CloudContentHash {
    public static func dropbox(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var outer = SHA256()
        while let bytes = try handle.read(upToCount: 4 << 20), !bytes.isEmpty { outer.update(data: Data(SHA256.hash(data: bytes))) }
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func dropbox(_ bytes: Data) -> String {
        var outer = SHA256()
        for offset in stride(from: 0, to: bytes.count, by: 4 << 20) {
            outer.update(data: Data(SHA256.hash(data: bytes[offset..<min(bytes.count, offset + (4 << 20))])))
        }
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
