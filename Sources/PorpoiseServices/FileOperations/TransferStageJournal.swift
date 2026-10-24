import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Crash records for private local staging and claimed move sources. Writes finish before destructive work.
public final class TransferStageJournal: @unchecked Sendable {
    public static let shared = TransferStageJournal(
        folder: JournalStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("TransferStages"))
    struct Identity: Codable, Equatable, Sendable {
        let volume: String
        let inode: UInt64
        init(_ url: URL, volumeUUID: (URL) -> String?) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let volumeURL = info.st_mode & S_IFMT == S_IFLNK ? url.deletingLastPathComponent() : url
            if let uuid = volumeUUID(volumeURL) {
                volume = "uuid:" + uuid
            } else {
                var filesystem = statfs()
                if statfs(volumeURL.path, &filesystem) == 0 {
                    let from = withUnsafeBytes(of: filesystem.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    let type = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    let mount = URL(string: from.hasPrefix("//") ? "mount:" + from : from)
                    let safe = mount.map(RemoteFS.withoutPassword)?.absoluteString ?? from
                    var hash = ChecksumHasher(.sha256)
                    hash.update(Data(safe.utf8))
                    volume = "mount:" + type + ":" + hash.finalize()
                } else {
                    volume = "device:\(info.st_dev)"
                }
            }
            inode = info.st_ino
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
        var deleting = false
        var preserved = false
    }
    public struct Retained: Sendable {
        public let url: URL
        public let message: String
    }
    let store: CloudJournal<Record>
    private let lock = NSLock()
    private let volumeUUID: @Sendable (URL) -> String?
    private var active: Set<UUID> = []
    private static let recoveryQueue = DispatchQueue(label: "porpoise.transfer-stage-recovery", qos: .utility)

    public convenience init(folder: URL) {
        self.init(folder: folder, volumeUUID: { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
    }
    init(folder: URL, volumeUUID: @escaping @Sendable (URL) -> String?) {
        store = CloudJournal(folder: folder)
        self.volumeUUID = volumeUUID
    }
    private func identity(_ url: URL) throws -> Identity { try Identity(url, volumeUUID: volumeUUID) }

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
                    operationID: id, holding: holding, identity: identity(holding), parentIdentity: identity(holding.deletingLastPathComponent()))
            guard try identity(holding) == record.identity else { throw CloudJournalError.invalidRecord }
            record.source = source; record.target = target.map(RemoteFS.withoutPassword); record.verified = verified
            if record.sourceIdentity == nil { record.sourceIdentity = try identity(source) }
            if verified, let target, target.isFileURL { record.targetIdentity = try identity(target) }
            try saveActive(record)
        case .finished(let holding): try finish(holding)
        case .deleting(let holding):
            guard var record = try store.load(id(holding)) else { throw CloudJournalError.invalidRecord }
            record.deleting = true
            try saveActive(record)
        case .deletingEntry: break
        }
    }

    func stage(_ holding: URL) throws {
        let id = try id(holding)
        try saveActive(
            Record(operationID: id, holding: holding, identity: identity(holding), parentIdentity: identity(holding.deletingLastPathComponent())))
    }
    public func publicationCheckpoint(_ checkpoint: FilePublication.Checkpoint) throws {
        switch checkpoint {
        case .protecting(let holding, let original, let incoming):
            let id = try id(holding)
            var record =
                try store.load(id)
                ?? Record(
                    operationID: id, holding: holding, identity: identity(holding), parentIdentity: identity(holding.deletingLastPathComponent()))
            guard try identity(holding) == record.identity else { throw CloudJournalError.invalidRecord }
            record.source = original; record.sourceIdentity = try identity(original)
            record.target = incoming; record.targetIdentity = try identity(incoming)
            record.preserved = true
            try saveActive(record)
        case .previousClaimed: break
        case .finished(let holding): try finish(holding)
        }
    }
    private func saveActive(_ record: Record) throws {
        let inserted = lock.withLock { active.insert(record.operationID).inserted }
        do { try store.save(record) } catch {
            if inserted { _ = lock.withLock { active.remove(record.operationID) } }
            throw error
        }
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
    public func recover(completion: @escaping @MainActor @Sendable ([Retained]) -> Void) {
        Self.recoveryQueue.async {
            let retained = self.recover()
            Task { @MainActor in completion(retained) }
        }
    }
    /// Must run off the main thread. A changed/missing target or uncertain ownership always retains data.
    func recover() -> [Retained] {
        var retained: [Retained] = []
        do {
            for var record in try store.all() {
                guard lock.withLock({ active.insert(record.operationID).inserted }) else { continue }
                defer { _ = lock.withLock { active.remove(record.operationID) } }
                do {
                    // An unmounted source volume must not look like an already removed holding folder.
                    guard let parent = try? identity(record.holding.deletingLastPathComponent()), parent.volume == record.parentIdentity.volume else {
                        continue
                    }
                    guard parent == record.parentIdentity else {
                        throw CloudJournalError.invalidRecord
                    }
                    if !FileJob.itemExists(at: record.holding) { try finish(record.holding); continue }
                    guard try identity(record.holding) == record.identity, !record.preserved else { throw CloudJournalError.invalidRecord }
                    if let source = record.source {
                        let claimed = record.holding.appendingPathComponent(source.lastPathComponent)
                        if FileJob.itemExists(at: claimed) {
                            guard try identity(claimed) == record.sourceIdentity else { throw CloudJournalError.invalidRecord }
                            if !record.verified {
                                guard !record.deleting else { throw CloudJournalError.invalidRecord }
                                try restore(claimed, to: source)
                            } else {
                                do {
                                    guard let target = record.target, let expectedTarget = record.targetIdentity,
                                        try identity(target) == expectedTarget
                                    else {
                                        throw CloudJournalError.invalidRecord
                                    }
                                    let receipt = try LocalMoveRemovalReceipt(
                                        source: claimed,
                                        onCheckpoint: { checkpoint in
                                            if case .deleting = checkpoint {
                                                var committing = record
                                                committing.deleting = true
                                                try self.store.save(committing)
                                                record = committing
                                            }
                                        })
                                    try receipt.removeSource(afterVerifying: target)
                                } catch {
                                    guard !record.deleting else { throw error }
                                    try restore(claimed, to: source)
                                }
                            }
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
    private func restore(_ claimed: URL, to source: URL) throws {
        try FilePublication.renameExclusively(claimed, to: source)
    }
}
