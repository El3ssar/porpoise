import Foundation

/// One durable operation owner for a content-store partial. Reads the old provider UUID-only sidecars.
struct CloudOperationSidecar {
    private struct Record: Codable {
        var version = 1
        var operation: UUID
        var partial: URL
        var account: String
        var item: String?
        var revision: String?
    }
    private static let lock = NSLock()
    let partial: URL
    let account: String
    let legacy: URL
    var item: CloudRemoteItem?
    private var url: URL { partial.appendingPathExtension("cloud-operation") }
    private static func canonicalPath(_ url: URL) -> String {
        let normalized = url.standardizedFileURL
        // The partial itself may not exist yet (or may already have moved into the store).
        return normalized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(normalized.lastPathComponent).path
    }
    func existing() throws -> UUID? { try Self.lock.withLock { try read() } }
    private func read() throws -> UUID? {
        if FileManager.default.fileExists(atPath: url.path) {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            // Directory enumeration can resolve the staging root's aliases (/var becomes /private/var).
            // Bind to the same canonical path while accepting both current and legacy URL spellings.
            guard record.version == 1,
                Self.canonicalPath(record.partial) == Self.canonicalPath(partial),
                record.account == account,
                item == nil || (record.item == item?.ref.item && record.revision == item?.revision)
            else { throw CloudContentError.changed }
            return record.operation
        }
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: legacy))
    }
    func operation() throws -> UUID {
        try Self.lock.withLock {
            let id = try read() ?? UUID()
            let record = Record(operation: id, partial: partial, account: account, item: item?.ref.item, revision: item?.revision)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
            let fd = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
            if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
            return id
        }
    }
    func remove() throws {
        try Self.lock.withLock {
            _ = try read()
            for path in [url, legacy] where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}
