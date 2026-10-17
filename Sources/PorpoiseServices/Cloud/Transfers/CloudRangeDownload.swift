import Foundation
import PorpoiseCore

public enum CloudTransferError: Error { case invalidResponse, sourceChanged }
public struct CloudDownloadRange: Codable, Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var offset: Int64
    public init(start: Int64, end: Int64, offset: Int64) { self.start = start; self.end = end; self.offset = offset }
}
public protocol CloudRangeDownloadRecord: CloudJournalRecord {
    var offset: Int64 { get set }
    var downloadRanges: [CloudDownloadRange]? { get set }
    var fingerprint: JobJournal.Fingerprint? { get set }
}

public enum CloudRangeDownload {
    public typealias Receive = (Data, HTTPURLResponse) async throws -> Void
    public typealias Fetch = @Sendable (Range<Int64>, @escaping Receive) async throws -> HTTPURLResponse
    public static func run<Record: CloudRangeDownloadRecord>(
        total: Int64, partial: URL, record: Record, context: CloudTransferContext, maximumConnections: Int,
        save: @escaping @Sendable (Record) throws -> Void, fetch: @escaping Fetch
    ) async throws -> Record {
        guard total >= 0 else { throw CloudTransferError.invalidResponse }
        if total == 0 {
            guard record.offset == 0, record.downloadRanges?.isEmpty != false else { throw CloudTransferError.sourceChanged }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try output.truncate(atOffset: 0); try output.synchronize()
            var record = record
            record.downloadRanges = []; record.fingerprint = JobJournal.Fingerprint(partial)
            try save(record); context.progress(0, 0)
            return record
        }
        let state = try CloudRangeWriter(
            partial: partial, total: total, record: record, save: save, maximumConnections: maximumConnections)
        context.progress(record.offset, total)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, range) in state.ranges.enumerated() where range.offset < range.end {
                    group.addTask {
                        var received = range.offset
                        let response = try await fetch(range.offset..<range.end) { data, response in
                            guard response.statusCode == 206,
                                response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.offset)-\(range.end - 1)/\(total)",
                                received + Int64(data.count) <= range.end
                            else { throw CloudTransferError.invalidResponse }
                            try await context.checkpoint()
                            let progress = try state.write(data, index: index, offset: received)
                            received += Int64(data.count)
                            if let progress { context.progress(progress, total) }
                        }
                        guard response.statusCode == 206, received == range.end else { throw CloudTransferError.invalidResponse }
                        try state.checkpoint(index: index, offset: received)
                    }
                }
                do { for try await _ in group {} } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            try state.preserve()
            throw error
        }
        return try state.finish()
    }
}

/// A single lock serializes file offsets and journal snapshots. Network reads remain concurrent.
/// Only fsynced bytes enter each range's durable offset; a retry overwrites unconfirmed tails.
private final class CloudRangeWriter<Record: CloudRangeDownloadRecord>: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    private let partial: URL
    private let save: @Sendable (Record) throws -> Void
    private var record: Record
    private var received: [Int64]
    private var checkpointAt: [Date]
    private var progressAt = Date.distantPast
    let ranges: [CloudDownloadRange]

    init(partial: URL, total: Int64, record: Record, save: @escaping @Sendable (Record) throws -> Void, maximumConnections: Int) throws {
        self.partial = partial; self.save = save
        var record = record
        if record.downloadRanges != nil {
            guard JobJournal.Fingerprint(partial)?.size == total else { throw CloudTransferError.sourceChanged }
        }
        if record.downloadRanges == nil {
            // Four streams for medium files, increasing with file size up to eight.
            let count = min(max(1, maximumConnections), min(8, max(4, Int((total - 1) / (64 << 20) + 1))))
            let width = total / Int64(count) + (total % Int64(count) == 0 ? 0 : 1)
            record.downloadRanges = (0..<count).map { index in
                let start = Int64(index) * width, end = index == count - 1 ? total : Int64(index + 1) * width
                return .init(start: start, end: end, offset: min(end, max(start, record.offset)))
            }
        }
        ranges = record.downloadRanges!
        var end: Int64 = 0
        for range in ranges {
            guard range.start == end, range.start <= range.offset, range.offset <= range.end, range.end > range.start, range.end <= total else {
                throw CloudTransferError.invalidResponse
            }
            end = range.end
        }
        guard end == total, ranges.count <= 8, record.offset == ranges.reduce(0, { $0 + ($1.offset - $1.start) }) else {
            throw CloudTransferError.invalidResponse
        }
        output = try FileHandle(forWritingTo: partial)
        try output.truncate(atOffset: UInt64(total)); try output.synchronize()
        record.fingerprint = JobJournal.Fingerprint(partial)
        try save(record)
        self.record = record
        received = ranges.map(\.offset); checkpointAt = ranges.map { _ in Date() }
    }

    deinit { try? output.close() }

    func write(_ data: Data, index: Int, offset: Int64) throws -> Int64? {
        try lock.withLock {
            try output.seek(toOffset: UInt64(offset)); try output.write(contentsOf: data)
            received[index] = offset + Int64(data.count)
            if received[index] - record.downloadRanges![index].offset >= 8 << 20 || Date().timeIntervalSince(checkpointAt[index]) >= 2 {
                try persist(index: index, offset: received[index])
            }
            guard Date().timeIntervalSince(progressAt) >= 0.1 else { return nil }
            progressAt = Date()
            return zip(received, ranges).reduce(0) { $0 + ($1.0 - $1.1.start) }
        }
    }

    func checkpoint(index: Int, offset: Int64) throws {
        try lock.withLock { try persist(index: index, offset: offset) }
    }

    private func persist(index: Int, offset: Int64) throws {
        try output.synchronize()
        record.downloadRanges![index].offset = offset
        record.offset = record.downloadRanges!.reduce(0) { $0 + ($1.offset - $1.start) }
        record.fingerprint = JobJournal.Fingerprint(partial)
        try save(record); checkpointAt[index] = Date()
    }

    func preserve() throws {
        try lock.withLock {
            try output.synchronize()
            record.fingerprint = JobJournal.Fingerprint(partial)
            try save(record)
        }
    }

    func finish() throws -> Record {
        try lock.withLock {
            guard record.downloadRanges!.allSatisfy({ $0.offset == $0.end }) else { throw CloudTransferError.invalidResponse }
            return record
        }
    }
}
