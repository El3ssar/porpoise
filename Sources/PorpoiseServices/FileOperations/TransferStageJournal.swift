import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Crash records for private local staging and claimed move sources. Writes finish before destructive work.
public final class TransferStageJournal: @unchecked Sendable {
    public static let shared = TransferStageJournal(
        folder: JournalStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("TransferStages"))
    struct Identity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = info.st_dev; inode = info.st_ino
        }
    }
    struct Record: CloudJournalRecord {
        var version = 1
        let operationID: UUID
        let holding: URL
        let identity: Identity
        let parentIdentity: Identity
        var source: URL?
        var sourceIdentity: Identity?
        var target: URL?
        var targetIdentity: Identity?
        var verified = false
        var preserved = false
    }
    public struct Retained: Sendable {
        public let url: URL
        public let message: String
    }
    let store: CloudJournal<Record>
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private static let recoveryQueue = DispatchQueue(label: "porpoise.transfer-stage-recovery", qos: .utility)

    public init(folder: URL) { store = CloudJournal(folder: folder) }

    private func id(_ holding: URL) throws -> UUID {
        guard let id = UUID(uuidString: String(holding.lastPathComponent.suffix(36))) else { throw CloudJournalError.invalidRecord }
        return id
    }
    public func checkpoint(_ checkpoint: LocalMoveRemovalReceipt.Checkpoint) throws {
        switch checkpoint {
        case .claimed(let holding, let source, let target, let verified):
            let id = try id(holding)
            var record =
                try store.load(id)
                ?? Record(
                    operationID: id, holding: holding, identity: Identity(holding), parentIdentity: Identity(holding.deletingLastPathComponent()))
            guard try Identity(holding) == record.identity else { throw CloudJournalError.invalidRecord }
            record.source = source; record.target = target; record.verified = verified
            if record.sourceIdentity == nil { record.sourceIdentity = try Identity(source) }
            if verified, let target, target.isFileURL { record.targetIdentity = try Identity(target) }
            try store.save(record)
            _ = lock.withLock { active.insert(id) }
        case .finished(let holding): try finish(holding)
        case .deleting: break
        }
    }

    func stage(_ holding: URL) throws {
        let id = try id(holding)
        try store.save(
            Record(operationID: id, holding: holding, identity: Identity(holding), parentIdentity: Identity(holding.deletingLastPathComponent())))
        _ = lock.withLock { active.insert(id) }
    }
    func preserve(_ holding: URL) throws {
        let id = try id(holding)
        guard var record = try store.load(id) else { return }
        record.preserved = true
        try store.save(record)
    }
    func finish(_ holding: URL) throws {
        let id = try id(holding)
        try store.remove(id)
        _ = lock.withLock { active.remove(id) }
    }
    /// An ended job may have retained a holding tree; make it eligible for the next recovery pass.
    func release(_ holding: URL) {
        if let id = try? id(holding) { _ = lock.withLock { active.remove(id) } }
    }
    public func recover(completion: @escaping @Sendable ([Retained]) -> Void) {
        Self.recoveryQueue.async { completion(self.recover()) }
    }
    /// Must run off the main thread. A changed/missing target or uncertain ownership always retains data.
    func recover() -> [Retained] {
        var retained: [Retained] = []
        do {
            for record in try store.all() {
                if lock.withLock({ active.contains(record.operationID) }) { continue }
                do {
                    // An unmounted source volume must not look like an already removed holding folder.
                    guard try Identity(record.holding.deletingLastPathComponent()) == record.parentIdentity else {
                        throw CloudJournalError.invalidRecord
                    }
                    if !FileJob.itemExists(at: record.holding) { try finish(record.holding); continue }
                    guard try Identity(record.holding) == record.identity, !record.preserved else { throw CloudJournalError.invalidRecord }
                    if let source = record.source {
                        let claimed = record.holding.appendingPathComponent(source.lastPathComponent)
                        if FileJob.itemExists(at: claimed) {
                            guard record.verified, let target = record.target, let identity = record.targetIdentity,
                                try Identity(target) == identity, try Identity(claimed) == record.sourceIdentity
                            else { throw CloudJournalError.invalidRecord }
                            let receipt = try LocalMoveRemovalReceipt(source: claimed)
                            try receipt.removeSource(afterVerifying: target)
                        }
                        // Never remove a partially deleted tree or an independently claimed leftover.
                        guard rmdir(record.holding.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    } else {
                        // Remote download staging contains only unpublished temporary bytes.
                        try FileManager.default.removeItem(at: record.holding)
                    }
                    try finish(record.holding)
                } catch {
                    retained.append(
                        Retained(
                            url: record.holding,
                            message: "An interrupted transfer kept files at “\(record.holding.path)”. Review them before removing anything."))
                }
            }
        } catch {
            retained.append(Retained(url: store.folder, message: "Transfer recovery records could not be read. They have been kept for review."))
        }
        return retained
    }
}
