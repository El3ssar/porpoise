import CryptoKit
import Foundation

/// Account-scoped, bounded disk LRU. Only downloaded preview bytes live here; never credentials.
public actor DriveMediaCache {
    private let directory: URL
    private let byteLimit: Int
    private var generation = 0

    public init(accountID: UUID, directory: URL? = nil, byteLimit: Int = 200 << 20) {
        self.directory =
            directory
            ?? DriveMetadataCache.root.appendingPathComponent(accountID.uuidString).appendingPathComponent("Previews", isDirectory: true)
        self.byteLimit = byteLimit
    }

    public func clear() {
        generation += 1
        try? FileManager.default.removeItem(at: directory)
    }

    public func file(key: String, name: String, load: @Sendable () async throws -> Data) async throws -> URL {
        // Provider names are untrusted. The hash owns the directory; names cannot escape it.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw DriveError.invalidResponse
        }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(hash).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        let epoch = generation
        let data = try await load()
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard data.count <= byteLimit else { throw DriveError.invalidResponse }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
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
