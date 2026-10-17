import Foundation
import PorpoiseCore

public struct CloudTransferSnapshot: Codable, Sendable, Equatable {
    public var item: CloudRemoteItem
    public var headRevision: String?
    public var nativeType: String?
    public init(item: CloudRemoteItem, headRevision: String? = nil, nativeType: String? = nil) {
        self.item = item; self.headRevision = headRevision; self.nativeType = nativeType
    }
    func matches(_ other: Self) -> Bool {
        guard item.ref == other.item.ref, item.isFolder == other.item.isFolder else { return false }
        if item.isFolder { return true }  // Child operations journal the contents of recursive merges.
        return item.revision == other.item.revision && headRevision == other.headRevision
            && item.size == other.item.size && item.checksum == other.item.checksum && nativeType == other.nativeType
    }
}
public struct CloudTransferReceipt: Codable, Sendable {
    public var url: URL
    public var snapshot: CloudTransferSnapshot?
    public var fingerprint: JobJournal.Fingerprint?
    public var digest: String?
    public var sourceRemoved = false
    public init(
        url: URL, snapshot: CloudTransferSnapshot? = nil, fingerprint: JobJournal.Fingerprint? = nil, digest: String? = nil,
        sourceRemoved: Bool = false
    ) {
        self.url = url; self.snapshot = snapshot; self.fingerprint = fingerprint; self.digest = digest; self.sourceRemoved = sourceRemoved
    }
}
public struct CloudTransferRepresentation: Equatable, Sendable {
    public var name: String
    public var allowsMove = true
    public init(name: String, allowsMove: Bool = true) { self.name = name; self.allowsMove = allowsMove }
}

/// A provider-neutral parent operation. Provider upload/session records remain private child operations.
public struct CloudTransferRecord: CloudJournalRecord, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, transferring, committed, sourceRemovalPending, done }
    public var version = 1
    public let operationID: UUID
    public var batchID: UUID?
    public var kind: String
    public var source: URL
    public var destinationFolder: URL
    public var topLevel = false
    public var sourceAccount: String?
    public var destinationAccount: String?
    public var sourceSnapshot: CloudTransferSnapshot?
    public var sourceFingerprint: JobJournal.Fingerprint?
    public var sourceRevision: String?
    public var name: String?
    public var childOperationID: UUID?
    public var downloadOperationID: UUID?
    public var targetURL: URL?
    public var receipt: CloudTransferReceipt?
    public var native = false
    public var skipped = false
    public var skippedIdentical = false
    public var stagingURL: URL?
    public var stagingFingerprint: JobJournal.Fingerprint?
    public var phase: Phase = .prepared
    public init(operationID: UUID, kind: String, source: URL, destinationFolder: URL) {
        self.operationID = operationID; self.kind = kind; self.source = source; self.destinationFolder = destinationFolder
    }
}

/// Canonical records live beside, not inside, provider mutation records. Legacy imports are idempotent by UUID.
public final class CloudTransferJournal: @unchecked Sendable {
    public static let shared = CloudTransferJournal.at(JournalStore.defaultFolder.appendingPathComponent("CloudTransfers"))
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CloudTransferJournal] = [:]
    private struct Active { var operation: UUID; var accounts: [String]; var control: JobControl }
    nonisolated(unsafe) private static var active: [String: Active] = [:]
    nonisolated(unsafe) private static var blocked: Set<String> = []
    nonisolated(unsafe) private static var waiters: [(String, CheckedContinuation<Void, Never>)] = []
    private static func matches(_ account: String, _ candidate: String) -> Bool { candidate == account || candidate.hasPrefix(account + ":") }
    private static func isBlocked(_ accounts: [String]) -> Bool { blocked.contains { account in accounts.contains { matches(account, $0) } } }
    static func allow(account: String) { _ = registryLock.withLock { blocked.remove(account) } }
    static func stop(account: String) async {
        let controls = registryLock.withLock {
            blocked.insert(account)
            return active.values.filter { entry in entry.accounts.contains { matches(account, $0) } }.map(\.control)
        }
        controls.forEach { $0.cancel() }
        await withCheckedContinuation { continuation in
            let waits = registryLock.withLock {
                guard active.values.contains(where: { entry in entry.accounts.contains { matches(account, $0) } }) else { return false }
                waiters.append((account, continuation)); return true
            }
            if !waits { continuation.resume() }
        }
    }
    public let folder: URL
    private let storage: CloudJournal<CloudTransferRecord>
    private let lock = NSLock()
    private var legacy: ((UUID?) throws -> [CloudTransferRecord])?
    private init(folder: URL) { self.folder = folder; storage = CloudJournal(folder: folder) }
    static func at(_ folder: URL, legacy: ((UUID?) throws -> [CloudTransferRecord])? = nil) -> CloudTransferJournal {
        registryLock.withLock {
            let key = folder.standardizedFileURL.path
            let journal = registry[key] ?? CloudTransferJournal(folder: URL(fileURLWithPath: key, isDirectory: true)); registry[key] = journal
            if let legacy { journal.lock.withLock { journal.legacy = legacy } }
            return journal
        }
    }
    private func importLegacy(_ id: UUID? = nil) throws {
        let read = lock.withLock { legacy }
        for record in try read?(id) ?? [] where try storage.load(record.operationID) == nil {
            do { try save(record) } catch CloudContentError.offline { continue }
        }
    }
    private func key(_ id: UUID) -> String { folder.path + "/" + id.uuidString }
    func claim(_ id: UUID, accounts: [String], control: JobControl) throws {
        try Self.registryLock.withLock {
            guard !Self.isBlocked(accounts) else { throw CloudContentError.offline }
            try storage.claim(id); Self.active[key(id)] = Active(operation: id, accounts: accounts, control: control)
        }
    }
    func release(_ id: UUID) {
        let ready: [CheckedContinuation<Void, Never>] = Self.registryLock.withLock {
            storage.release(id)
            Self.active[key(id)] = nil
            var ready: [CheckedContinuation<Void, Never>] = []
            Self.waiters.removeAll { account, continuation in
                guard !Self.active.values.contains(where: { entry in entry.accounts.contains { Self.matches(account, $0) } }) else { return false }
                ready.append(continuation); return true
            }
            return ready
        }
        ready.forEach { $0.resume() }
    }
    public func load(_ id: UUID) throws -> CloudTransferRecord? {
        if let record = try storage.load(id) { return record }
        try importLegacy(id); return try storage.load(id)
    }
    public func save(_ record: CloudTransferRecord) throws {
        try Self.registryLock.withLock {
            let accounts = [record.sourceAccount, record.destinationAccount].compactMap({ $0 })
            let finishing = Self.active[key(record.operationID)] != nil && (record.phase == .committed || record.phase == .done)
            guard !Self.isBlocked(accounts) || finishing else { throw CloudContentError.offline }
            try storage.save(record)
        }
    }
    public func all() throws -> [CloudTransferRecord] { try importLegacy(); return try storage.all() }
    func forget(account: String) throws {
        for record in try storage.all()
        where [record.sourceAccount, record.destinationAccount].compactMap({ $0 }).contains(where: { Self.matches(account, $0) }) {
            let sources = folder.appendingPathComponent("Sources").appendingPathComponent(record.operationID.uuidString)
            if FileManager.default.fileExists(atPath: sources.path) { try FileManager.default.removeItem(at: sources) }
            try storage.remove(record.operationID)
        }
    }
    static func isActive(_ record: CloudTransferRecord) -> Bool {
        registryLock.withLock { active.values.contains { $0.operation == record.operationID || $0.operation == record.batchID } }
    }
    static var known: [CloudTransferJournal] { registryLock.withLock { Array(registry.values) } }
}
