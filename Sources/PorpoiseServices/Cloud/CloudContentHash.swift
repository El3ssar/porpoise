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

/// Microsoft's QuickXorHash (OneDrive, SharePoint): each byte is XORed into a 160-bit ring, eleven bits further on than the
/// one before; the input length is XORed into the last 64 bits. Base64 of the 20 bytes.
/// https://learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash
public struct QuickXorHash: Sendable {
    private static let width = 160, shift = 11
    private var cells: [UInt64] = [0, 0, 0]
    private var shifted = 0
    private var length: UInt64 = 0
    public init() {}
    public mutating func update(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var index = shifted / 64, offset = shifted % 64
            for i in 0..<min(count, Self.width) {
                let last = index == cells.count - 1, bits = last ? 32 : 64
                var folded: UInt8 = 0
                for j in stride(from: i, to: count, by: Self.width) { folded ^= raw[j] }
                if offset <= bits - 8 {
                    cells[index] ^= UInt64(folded) << UInt64(offset)
                } else {
                    cells[index] ^= UInt64(folded) << UInt64(offset)
                    cells[last ? 0 : index + 1] ^= UInt64(folded) >> UInt64(bits - offset)
                }
                offset += Self.shift
                while offset >= bits {
                    index = last ? 0 : index + 1; offset -= bits
                }
            }
            shifted = (shifted + Self.shift * (count % Self.width)) % Self.width
            length += UInt64(count)
        }
    }
    public func finalize() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: cells[0] >> UInt64(8 * i)) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: cells[1] >> UInt64(8 * i)) }
        for i in 0..<4 { bytes[16 + i] = UInt8(truncatingIfNeeded: cells[2] >> UInt64(8 * i)) }
        for i in 0..<8 { bytes[12 + i] ^= UInt8(truncatingIfNeeded: length >> UInt64(8 * i)) }
        return Data(bytes).base64EncodedString()
    }
}
extension CloudContentHash {
    /// QuickXorHash read 1 MiB at a time: never the whole file in memory.
    public static func quickXor(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = QuickXorHash()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(bytes) }
        return hash.finalize()
    }
    public static func quickXor(_ bytes: Data) -> String { var hash = QuickXorHash(); hash.update(bytes); return hash.finalize() }
}

extension CloudContentHash {
    /// SHA-1 in lowercase hex (Box's `sha1`), read incrementally.
    public static func sha1(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func sha1(_ bytes: Data) -> String { Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
