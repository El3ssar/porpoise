import Foundation
import PorpoiseCore

protocol CloudStagedDownloadRecord: CloudRangeDownloadRecord {
    var stagedURL: URL? { get set }
    var stagedComplete: Bool { get set }
    mutating func beginDownload()
}
protocol CloudStagedDownloadJournal: Sendable {
    associatedtype Record: CloudStagedDownloadRecord
    var folder: URL { get }
    func claim(_ id: UUID) throws
    func release(_ id: UUID)
    func load(_ id: UUID) throws -> Record?
    func save(_ record: Record) throws
    func partial(_ id: UUID) -> URL
    func remove(_ id: UUID) throws
}

/// Owns private bytes and durable checkpoints; providers supply identity, transport and final revision checks.
enum CloudStagedDownload {
    /// A caller with no recovery contract owns its temporary operation until the consumed copy is published.
    static func consume<J: CloudStagedDownloadJournal, Value>(
        journal: J, download: (UUID) async throws -> URL, using consume: (URL) throws -> Value
    ) async throws -> Value {
        let operation = UUID()

        do {
            let partial = try await download(operation)
            let value = try consume(partial)
            try discard(operation, journal: journal); return value
        } catch {
            try? discard(operation, journal: journal); throw error
        }
    }
    static func discard<J: CloudStagedDownloadJournal>(_ operation: UUID, journal: J) throws {
        try journal.claim(operation); defer { journal.release(operation) }
        guard let record = try journal.load(operation) else { return }
        let partial = journal.partial(operation)
        guard record.stagedURL == nil || record.stagedURL == partial else { throw CloudTransferError.sourceChanged }
        try removeOwned(partial, fingerprint: record.fingerprint)
        try journal.remove(operation)
    }
    /// A crash after publication into the offline store's partial must not cause another media request.
    static func reuseVerified(_ item: CloudRemoteItem, partial: URL, refresh: () async throws -> CloudRemoteItem) async throws -> Bool {
        guard item.export == nil, let checksum = item.checksum, let size = item.size,
            FileManager.default.fileExists(atPath: partial.path), JobJournal.Fingerprint(partial)?.size == size,
            try checksum.verify(partial)
        else { return false }
        let fresh = try await refresh()
        guard fresh.ref == item.ref, fresh.revision == item.revision, fresh.checksum == item.checksum, fresh.size == size else {
            throw CloudContentError.changed
        }
        return true
    }
    static func removeOwned(_ partial: URL, fingerprint: JobJournal.Fingerprint?) throws {
        guard FileManager.default.fileExists(atPath: partial.path) else { return }
        guard let fingerprint, JobJournal.Fingerprint(partial) == fingerprint else { throw CloudTransferError.sourceChanged }
        try FileManager.default.removeItem(at: partial)
    }
    enum Transfer {
        case binary(total: Int64, connections: Int, ranges: Bool)
        case data(load: () async throws -> Data)
    }
    typealias Fetch = (Range<Int64>?, @escaping CloudRangeDownload.Receive) async throws -> HTTPURLResponse
    static func run<J: CloudStagedDownloadJournal, File>(
        journal: J, operationID: UUID, context: CloudTransferContext, transfer: Transfer, checksum: CloudChecksum?,
        exactFingerprint: Bool = true,
        prepare: (J.Record?) throws -> J.Record, fetch: @escaping Fetch,
        verify: () async throws -> File, finish: (inout J.Record, File) -> Void
    ) async throws -> (URL, File) {
        try journal.claim(operationID); defer { journal.release(operationID) }
        let partial = journal.partial(operationID)
        var record = try prepare(journal.load(operationID))
        if record.stagedComplete {
            guard record.stagedURL == partial, JobJournal.Fingerprint(partial) == record.fingerprint else { throw CloudTransferError.sourceChanged }
            if let checksum, try !checksum.verify(partial) { throw CloudContentError.checksum }
            return (partial, try await verify())
        }
        try await context.checkpoint()
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard record.offset == 0, record.downloadRanges == nil, record.fingerprint == nil else { throw CloudTransferError.sourceChanged }
            let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CloudTransferError.sourceChanged }; close(fd)
        } else if let expected = record.fingerprint {
            guard let actual = JobJournal.Fingerprint(partial), exactFingerprint ? actual == expected : actual.inode == expected.inode else {
                throw CloudTransferError.sourceChanged
            }
        } else {
            throw CloudTransferError.sourceChanged
        }
        record.stagedURL = partial; record.fingerprint = JobJournal.Fingerprint(partial); record.beginDownload()
        try journal.save(record)
        switch transfer {
        case .binary(let total, let connections, let ranges):
            guard total >= 0 else { throw CloudTransferError.invalidResponse }
            if ranges || record.downloadRanges != nil {
                record = try await CloudRangeDownload.run(
                    total: total, partial: partial, record: record, context: context,
                    maximumConnections: connections, save: { try journal.save($0) }, fetch: { range, receive in try await fetch(range, receive) })
            } else {
                record = try await serial(total: total, partial: partial, record: record, journal: journal, context: context, fetch: fetch)
            }
        case .data(let load):
            let bytes = try await load()
            let output = try FileHandle(forWritingTo: partial); defer { try? output.close() }
            try output.truncate(atOffset: 0); try output.write(contentsOf: bytes); try output.synchronize()
            record.offset = Int64(bytes.count)
        }
        if let checksum, try !checksum.verify(partial) { throw CloudContentError.checksum }
        let file = try await verify()
        record.stagedURL = partial; record.fingerprint = JobJournal.Fingerprint(partial); record.stagedComplete = true
        finish(&record, file); try journal.save(record); context.progress(record.offset, record.offset)
        return (partial, file)
    }
    private static func serial<J: CloudStagedDownloadJournal>(
        total: Int64, partial: URL, record: J.Record, journal: J, context: CloudTransferContext, fetch: @escaping Fetch
    ) async throws -> J.Record {
        var record = record
        let output = try FileHandle(forWritingTo: partial); defer { try? output.close() }
        guard (JobJournal.Fingerprint(partial)?.size ?? -1) >= record.offset else { throw CloudTransferError.sourceChanged }
        try output.truncate(atOffset: UInt64(record.offset)); try output.seek(toOffset: UInt64(record.offset))
        let start = record.offset, ranged = total >= 8 << 20 || record.offset > 0
        var received = start, buffered = Data(), checkpointAt = Date(), progressAt = Date.distantPast
        context.progress(received, total)
        do {
            if received < total {
                let response = try await fetch(ranged ? start..<total : nil) { data, response in
                    guard
                        ranged
                            ? response.statusCode == 206
                                && response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(total - 1)/\(total)"
                            : response.statusCode == 200,
                        received + Int64(data.count) <= total
                    else { throw CloudTransferError.invalidResponse }
                    try await context.checkpoint(); buffered.append(data); received += Int64(data.count)
                    if buffered.count >= 1 << 20 { try output.write(contentsOf: buffered); buffered.removeAll(keepingCapacity: true) }
                    if received - record.offset >= 8 << 20 || Date().timeIntervalSince(checkpointAt) >= 2 {
                        try output.write(contentsOf: buffered); buffered.removeAll(keepingCapacity: true); try output.synchronize()
                        record.offset = received; record.fingerprint = JobJournal.Fingerprint(partial); try journal.save(record);
                        checkpointAt = Date()
                    }
                    if received == total || Date().timeIntervalSince(progressAt) >= 0.1 { context.progress(received, total); progressAt = Date() }
                }
                guard response.statusCode == (ranged ? 206 : 200), received == total else { throw CloudTransferError.invalidResponse }
            }
        } catch {
            try output.truncate(atOffset: UInt64(record.offset)); try output.synchronize()
            record.fingerprint = JobJournal.Fingerprint(partial); try journal.save(record); throw error
        }
        try output.write(contentsOf: buffered); try output.synchronize()
        record.offset = received; record.fingerprint = JobJournal.Fingerprint(partial); try journal.save(record)
        return record
    }
}

extension CloudJournal: CloudStagedDownloadJournal where Record: CloudStagedDownloadRecord {}
