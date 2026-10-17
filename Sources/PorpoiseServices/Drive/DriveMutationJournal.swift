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
public struct DriveMutationRecord: CloudJournalRecord, Equatable {
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
    public typealias DownloadRange = CloudDownloadRange
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
    private let storage: CloudJournal<DriveMutationRecord>
    public init(folder: URL) { self.folder = folder; storage = CloudJournal(folder: folder) }
    func claim(_ id: UUID) throws {
        do { try storage.claim(id) } catch CloudJournalError.busy { throw DriveMutationError.busy }
    }
    func release(_ id: UUID) { storage.release(id) }
    public func load(_ id: UUID) throws -> DriveMutationRecord? {
        do { return try storage.load(id) } catch CloudJournalError.invalidRecord { throw DriveError.invalidResponse }
    }
    public func save(_ record: DriveMutationRecord) throws { try storage.save(record) }
    public func remove(_ id: UUID) throws { try storage.remove(id) }
    /// A download's private partial copy (0600, under the journal).
    public func partial(_ operationID: UUID) -> URL {
        storage.partial(operationID)
    }
    public func all(accountID: UUID? = nil) throws -> [DriveMutationRecord] {
        try storage.all().filter { accountID == nil || $0.accountID == accountID }
    }
}
