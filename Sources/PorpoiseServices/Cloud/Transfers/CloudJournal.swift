import Foundation

public enum CloudJournalError: Error { case busy, invalidRecord }
public protocol CloudJournalRecord: Codable, Sendable {
    var operationID: UUID { get }
    var version: Int { get }
}

/// Provider-independent operation ownership and atomic, fsynced recovery records. Secrets never belong in a record.
public final class CloudJournal<Record: CloudJournalRecord>: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var active: Set<UUID> = []
    public init(folder: URL) { self.folder = folder }
    public func claim(_ id: UUID) throws {
        try lock.withLock { guard active.insert(id).inserted else { throw CloudJournalError.busy } }
    }
    public func release(_ id: UUID) { _ = lock.withLock { active.remove(id) } }
    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    public func load(_ id: UUID) throws -> Record? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url(id)))
            guard record.version == 1, record.operationID == id else { throw CloudJournalError.invalidRecord }
            return record
        }
    }
    public func save(_ record: Record) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(record).write(to: url(record.operationID), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(record.operationID).path)
            let handle = try FileHandle(forWritingTo: url(record.operationID))
            defer { try? handle.close() }
            try handle.synchronize()
            let fd = open(folder.path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        }
    }
    /// Forgets a record (sign-out: nothing of the account stays).
    public func remove(_ id: UUID) throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url(id).path) else { return }
            try FileManager.default.removeItem(at: url(id))
        }
    }
    public func all() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
                return try load(id)
            }
    }
}
