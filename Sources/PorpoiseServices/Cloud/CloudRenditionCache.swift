import CryptoKit
import Foundation
import PorpoiseCore

/// Account-scoped, bounded disk LRU. Only downloaded preview bytes live here; never credentials.
public actor CloudRenditionCache {
    private let directory: URL
    private let byteLimit: Int
    private var generation = 0

    private let invalidResponse: @Sendable () -> Error
    public init(directory: URL, byteLimit: Int = 200 << 20, invalidResponse: @escaping @Sendable () -> Error = { CloudTransferError.invalidResponse })
    {
        self.directory = directory; self.byteLimit = byteLimit; self.invalidResponse = invalidResponse
    }

    public func epoch() -> Int { generation }

    public func clear() {
        generation += 1
        try? FileManager.default.removeItem(at: directory)
    }

    public func file(key: String, name: String, load: @Sendable () async throws -> Data) async throws -> URL {
        let target = try target(key: key, name: name)
        if let cached = try cachedFile(key: key, name: name) { return cached }
        let epoch = generation
        let data = try await load()
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard data.count <= byteLimit else { throw invalidResponse() }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        trim(keeping: target)
        return target
    }

    private func target(key: String, name: String) throws -> URL {
        guard let name = RemoteParsing.localName(forRemote: name) else { throw invalidResponse() }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathComponent(name)
    }

    public func cachedFile(key: String, name: String) throws -> URL? {
        let target = try target(key: key, name: name)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return target
    }

    /// Imports verified disk bytes without buffering an entire movie in memory.
    public func importFile(_ source: URL, key: String, name: String, epoch: Int? = nil) throws -> URL {
        if let epoch, epoch != generation { throw CancellationError() }
        let target = try target(key: key, name: name)
        if let cached = try cachedFile(key: key, name: name) { return cached }
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= byteLimit else {
            throw CloudOpenError.tooLarge
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.copyItem(at: source, to: partial)
        try FileManager.default.moveItem(at: partial, to: target)
        trim(keeping: target)
        return target
    }

    private func trim(keeping target: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var bytes = files.reduce(0) { $0 + $1.1 }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where bytes > byteLimit && url != target {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            bytes -= size
        }
    }
}

public enum CloudOpenError: LocalizedError {
    case tooLarge
    public var errorDescription: String? {
        "This file is too large for the local cache. Copy it to a folder on this Mac to open it."
    }
}
