import Foundation
import PorpoiseCore

public enum DriveMutationError: LocalizedError, Equatable {
    case conflict, uncertain, sourceChanged, busy, invalidSession
    public var errorDescription: String? {
        switch self {
        case .conflict: return "This Drive item changed or several items have that name. Choose a destination explicitly."
        case .uncertain: return "Drive may have completed this operation. Review the recovered operation before trying again."
        case .sourceChanged: return "The source changed since this transfer began. The original has been kept."
        case .busy: return "This Drive operation is already running."
        case .invalidSession: return "Drive returned an invalid upload session. Reconnect and try again."
        }
    }
}

/// Compatibility name for the shared cloud transfer callbacks.
public typealias DriveTransferContext = CloudTransferContext

/// No session URI or credential is serialized here. Session secrets use the credential store by operation UUID.
public struct DriveMutationRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, requesting, transferring, committed, sourceRemovalPending, done }
    public var version = 1
    public let operationID: UUID
    public let accountID: UUID
    public let kind: String
    public let sourceID: String?
    public let parentID: String?
    public let name: String?
    public var itemID: String?
    public var batchID: UUID?
    public var childOperationID: UUID?
    public var downloadOperationID: UUID?
    public var destinationDigest: String?
    public var destinationURL: URL?
    public var destinationFolder: URL?
    public var destinationFingerprint: JobJournal.Fingerprint?
    public var topLevel: Bool?
    public var previousRevisionID: String?
    public var revision: String?
    public var localSource: URL?
    public var fingerprint: JobJournal.Fingerprint?
    public struct DownloadRange: Codable, Equatable, Sendable {
        public var start: Int64
        public var end: Int64
        public var offset: Int64
    }
    public var downloadRanges: [DownloadRange]?
    public var offset: Int64 = 0
    public var hasSession = false
    public var phase: Phase = .prepared
    public var result: DriveFile?

    public init(operationID: UUID, accountID: UUID, kind: String, sourceID: String? = nil, parentID: String? = nil, name: String? = nil) {
        self.operationID = operationID; self.accountID = accountID; self.kind = kind
        self.sourceID = sourceID; self.parentID = parentID; self.name = name
    }
}

/// Atomic, fsynced checkpoints. Failure to persist aborts before the next remote side effect.
public final class DriveMutationJournal: @unchecked Sendable {
    public static let shared = DriveMutationJournal(folder: JournalStore.defaultFolder.appendingPathComponent("Drive"))
    public let folder: URL
    private let lock = NSLock()
    private var active: Set<UUID> = []
    public init(folder: URL) { self.folder = folder }
    func claim(_ id: UUID) throws {
        try lock.withLock { guard active.insert(id).inserted else { throw DriveMutationError.busy } }
    }
    func release(_ id: UUID) { _ = lock.withLock { active.remove(id) } }
    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    public func load(_ id: UUID) throws -> DriveMutationRecord? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
            let record = try JSONDecoder().decode(DriveMutationRecord.self, from: Data(contentsOf: url(id)))
            guard record.version == 1, record.operationID == id else { throw DriveError.invalidResponse }
            return record
        }
    }
    public func save(_ record: DriveMutationRecord) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(record)
            try data.write(to: url(record.operationID), options: .atomic)
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
    public func all(accountID: UUID? = nil) throws -> [DriveMutationRecord] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try load(UUID(uuidString: $0.deletingPathExtension().lastPathComponent) ?? UUID()) }
            .filter { accountID == nil || $0.accountID == accountID }
    }
}
