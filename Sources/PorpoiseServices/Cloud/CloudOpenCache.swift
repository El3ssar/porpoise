import CryptoKit
import Foundation
import PorpoiseCore

/// Recent verified full files, separate from preview renditions and durable edits.
/// The offline store can replace this seam with its revision index when pinning is available.
public final class CloudOpenCache: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var generation = 0
    private let byteLimit: Int64

    public init(directory: URL, byteLimit: Int64 = 5 << 30) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    private func target(key: String, name: String) throws -> URL {
        try RemoteFS.checkName(name)
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathComponent(name)
    }

    public func epoch() -> Int { lock.withLock { generation } }

    /// Disk lookup only: no provider or HTTP calls.
    public func localCopy(key: String, name: String) throws -> URL? {
        try lock.withLock {
            let url = try target(key: key, name: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
    }

    /// The caller has verified revision, size and digest with the transfer engine.
    public func adopt(_ source: URL, key: String, name: String, epoch: Int? = nil) throws -> URL {
        try lock.withLock {
            if let epoch, epoch != generation { throw CancellationError() }
            let target = try target(key: key, name: name)
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw CloudOpenError.tooLarge }
            guard size <= byteLimit else { throw CloudOpenError.tooLarge }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: target.path) {
                let partial = target.deletingLastPathComponent().appendingPathComponent(".partial-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: partial) }
                try FileManager.default.copyItem(at: source, to: partial)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
                try FileManager.default.moveItem(at: partial, to: target)
            }
            trim(keeping: target)
            return target
        }
    }

    public func clear() {
        lock.withLock {
            generation += 1; try? FileManager.default.removeItem(at: directory)
        }
    }

    private func trim(keeping target: URL) {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        var files: [(URL, Int64, Date)] = []
        for case let url as URL in entries {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value
            else { continue }
            files.append((url, size, attributes[.modificationDate] as? Date ?? .distantPast))
        }
        var size = files.reduce(Int64(0)) { $0 + $1.1 }
        for (url, bytes, _) in files.sorted(by: { $0.2 < $1.2 })
        where size > byteLimit && url.standardizedFileURL.path != target.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); size -= bytes
        }
    }
}

public enum CloudOpenError: LocalizedError {
    case tooLarge
    public var errorDescription: String? {
        "This file is too large for the local cache. Copy it to a folder on this Mac to open it."
    }
}
