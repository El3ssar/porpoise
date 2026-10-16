import Darwin
import Foundation
import PorpoiseCore

public struct ComparedFile: Sendable {
    public let url: URL
    public let size: UInt64
    public let modified: Date?
    public let created: Date?
    public let permissions: String
    public let owner: String
    public let tags: [String]
    public let attributes: [String]
    public let text: String?

    public init(url: URL, readText: Bool) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.url = url; size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        modified = a[.modificationDate] as? Date; created = a[.creationDate] as? Date
        permissions = String(format: "%04o", (a[.posixPermissions] as? NSNumber)?.intValue ?? 0)
        owner = a[.ownerAccountName] as? String ?? "—"
        tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if count > 0 {
            var bytes = [CChar](repeating: 0, count: count)
            let n = listxattr(url.path, &bytes, count, XATTR_NOFOLLOW)
            let names =
                n > 0 ? bytes.prefix(n).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted() : []
            attributes = names.map { name in
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0, size <= 1 << 20 else { return "\(name) (\(max(0, size)) bytes)" }
                var value = [UInt8](repeating: 0, count: size)
                let read = getxattr(url.path, name, &value, size, 0, XATTR_NOFOLLOW)
                guard read == size else { return name + " (unreadable)" }
                var hash = ChecksumHasher(.sha256); hash.update(Data(value))
                return "\(name) · \(size) bytes · \(hash.finalize())"
            }
        } else {
            attributes = []
        }
        // Bounded full decoding. Larger inputs remain usable through streaming byte comparison and Info.
        if readText && size <= 128 * 1024 * 1024 {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.prefix(8192).contains(0) { text = nil } else { text = String(data: data, encoding: .utf8) }
        } else {
            text = nil
        }
    }
}

public enum FileComparison {
    /// Streaming comparison, bounded to two 1 MiB buffers, cancellable between reads. nil means byte-identical.
    public static func firstDifference(_ left: URL, _ right: URL, cancellation: DiskCancellation = DiskCancellation()) throws -> UInt64? {
        let a = try FileHandle(forReadingFrom: left), b = try FileHandle(forReadingFrom: right)
        defer { try? a.close(); try? b.close() }
        var offset: UInt64 = 0
        while true {
            try cancellation.check()
            let x = try a.read(upToCount: 1 << 20) ?? Data(), y = try b.read(upToCount: 1 << 20) ?? Data()
            if x != y {
                let common = min(x.count, y.count)
                for i in 0..<common where x[i] != y[i] { return offset + UInt64(i) }
                return offset + UInt64(common)
            }
            if x.isEmpty { return nil }; offset += UInt64(x.count)
        }
    }
}
