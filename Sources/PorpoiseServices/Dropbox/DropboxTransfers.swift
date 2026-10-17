import CryptoKit
import Foundation
import PorpoiseCore

public struct DropboxOperation: CloudRangeDownloadRecord {
    public var version = 1
    public var operationID: UUID
    public var kind: String
    public var path: String
    public var destination: String?
    public var revision: String?
    public var hash: String?
    public var total: Int64 = 0
    public var offset: Int64 = 0
    public var proposedOffset: Int64?
    public var phase = "prepared"
    public var hasSession = false
    public var localURL: URL?
    public var fingerprint: JobJournal.Fingerprint?
    public var downloadRanges: [CloudDownloadRange]?
    public var result: DropboxItem?
    public init(operationID: UUID, kind: String, path: String) { self.operationID = operationID; self.kind = kind; self.path = path }
}

/// Provider convenience API; the neutral checksum implementation is also used by CloudOfflineStore.
public enum DropboxContentHash {
    public static func hash(_ url: URL) throws -> String { try CloudContentHash.dropbox(url) }
    static func hash(_ bytes: Data) -> String { CloudContentHash.dropbox(bytes) }
}

extension DropboxClient {
    /// Exact revision reads for both the shared range engine and the selection-owned streaming proxy.
    func stream(_ item: DropboxItem, range: Range<Int64>, receive: @escaping CloudRangeDownload.Receive) async throws -> HTTPURLResponse {
        guard let rev = item.rev, let total = item.size, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= total else {
            throw DropboxError.invalidResponse
        }
        let request = try request("files/download", arguments: ["path": "rev:" + rev], content: true, range: range)
        do {
            let (_, response) = try await authorized.send(request, idempotent: true) { bytes, response in
                guard response.statusCode == 206, let header = response.value(forHTTPHeaderField: "Dropbox-API-Result"),
                    let data = header.data(using: .utf8), let actual = try? JSONDecoder().decode(DropboxItem.self, from: data),
                    actual.id == item.id, actual.rev == rev, actual.contentHash == item.contentHash, actual.size == total
                else { throw DropboxError.sourceChanged }
                try await receive(bytes, response)
            }
            reached(nil); return response
        } catch { reached(error); throw error }
    }
    public func readRange(_ item: DropboxItem, range: Range<Int64>) async throws -> Data {
        guard range.count <= 1 << 20 else { throw DropboxError.invalidResponse }
        var output = Data()
        let response = try await stream(item, range: range) { bytes, response in
            guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(item.size!)",
                output.count + bytes.count <= range.count
            else { throw DropboxError.invalidResponse }
            output.append(bytes)
        }
        guard response.statusCode == 206, output.count == range.count else { throw DropboxError.invalidResponse }; return output
    }
    public func streamingPreview(_ item: DropboxItem, contentType: String) throws -> CloudStreamingPreview {
        guard !item.isFolder, let size = item.size, item.rev != nil else { throw DropboxError.invalidLocation }
        return try CloudStreamingPreview(size: size, contentType: contentType) { [weak self] range in
            guard let self else { throw CancellationError() }; return try await self.readRange(item, range: range)
        }
    }
    /// The caller publishes these verified staging bytes with its own no-overwrite destination policy.
    public func download(
        _ item: DropboxItem, operationID: UUID = UUID(), maximumConnections: Int = 8,
        context: CloudTransferContext = .init()
    ) async throws -> URL {
        guard !item.isFolder, item.isDownloadable != false, let total = item.size, total >= 0,
            let rev = item.rev, let hash = item.contentHash
        else { throw DropboxError.invalidResponse }
        try journal.claim(operationID); defer { journal.release(operationID) }
        let folder = journal.folder.appendingPathComponent("Downloads")
        let partial = folder.appendingPathComponent(operationID.uuidString + ".part")
        var record = try journal.load(operationID) ?? DropboxOperation(operationID: operationID, kind: "download", path: item.id)
        guard record.kind == "download", record.phase != "cancelled", record.path == item.id,
            record.revision == nil || record.revision == rev,
            record.hash == nil || record.hash == hash
        else { throw DropboxError.sourceChanged }
        if record.phase == "done" {
            guard record.localURL == partial, JobJournal.Fingerprint(partial) == record.fingerprint,
                try DropboxContentHash.hash(partial) == hash
            else { throw DropboxError.sourceChanged }
            let fresh = try await metadata(item.id)
            guard fresh.rev == rev, fresh.contentHash == hash, fresh.size == total else { throw DropboxError.sourceChanged }
            return partial
        }
        try await context.checkpoint()
        if record.downloadRanges == nil {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw DropboxError.sourceChanged }; close(fd)
            record.revision = rev; record.hash = hash; record.total = total; record.localURL = partial
            record.fingerprint = JobJournal.Fingerprint(partial); try journal.save(record)
        } else {
            guard record.localURL == partial, JobJournal.Fingerprint(partial) == record.fingerprint else { throw DropboxError.sourceChanged }
        }
        record = try await CloudRangeDownload.run(
            total: total, partial: partial, record: record, context: context,
            maximumConnections: total < 32 << 20 ? 1 : maximumConnections,
            save: { try self.journal.save($0) },
            fetch: { range, receive in
                try await self.stream(item, range: range, receive: receive)
            })
        guard try DropboxContentHash.hash(partial) == hash else { throw CloudContentError.checksum }
        let fresh = try await metadata(item.id)
        guard fresh.rev == rev, fresh.contentHash == hash, fresh.size == total else { throw DropboxError.sourceChanged }
        record.phase = "done"; record.fingerprint = JobJournal.Fingerprint(partial); record.result = fresh
        try journal.save(record); context.progress(total, total); return partial
    }
    /// Session IDs stay in the credential store. No unconditional overwrite or autorename is ever attempted.
    public func upload(
        _ local: URL, to path: String, expectedRevision: String? = nil, operationID: UUID = UUID(),
        context: CloudTransferContext = .init()
    ) async throws -> DropboxItem {
        try validateTarget(path)
        guard path.hasPrefix("/"), !path.contains("\0"), let fingerprint = JobJournal.Fingerprint(local),
            (try? local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            throw DropboxError.invalidLocation
        }
        try journal.claim(operationID); defer { journal.release(operationID) }
        let hash = try DropboxContentHash.hash(local)
        let previous = try journal.load(operationID)
        var record = previous ?? DropboxOperation(operationID: operationID, kind: "upload", path: path)
        if previous == nil { record.revision = expectedRevision }
        guard record.kind == "upload", record.path == path, record.revision == expectedRevision,
            record.fingerprint == nil || record.fingerprint == fingerprint, record.hash == nil || record.hash == hash
        else {
            throw DropboxError.sourceChanged
        }
        if record.phase == "done", let result = record.result { return result }
        if record.phase == "conflict" { throw DropboxError.conflict }
        guard record.phase != "committing", record.phase != "uncertain" else { throw DropboxError.uncertain }
        record.revision = expectedRevision; record.localURL = local; record.fingerprint = fingerprint
        record.total = fingerprint.size; record.hash = hash
        try journal.save(record); try await context.checkpoint()
        if !record.hasSession {
            struct Started: Decodable { var session_id: String }
            let bytes = try await data("files/upload_session/start", arguments: ["close": false], content: true, body: Data())
            let started = try JSONDecoder().decode(Started.self, from: bytes)
            guard !started.session_id.isEmpty else { throw DropboxError.invalidResponse }
            try await tokens.saveSecret(started.session_id, id: operationID)
            record.hasSession = true; try journal.save(record)
        }
        guard let session = try await tokens.secret(operationID) else { throw DropboxError.uncertain }
        if record.phase == "appending" {
            do {
                _ = try await data(
                    "files/upload_session/append_v2", arguments: ["cursor": ["session_id": session, "offset": record.offset]], content: true,
                    body: Data())
            } catch DropboxError.offset(let offset) {
                guard offset >= record.offset, offset <= (record.proposedOffset ?? record.offset), offset <= record.total else {
                    throw DropboxError.invalidResponse
                }
                record.offset = offset
            }
            record.phase = "prepared"; record.proposedOffset = nil; try journal.save(record)
        }
        let input = try FileHandle(forReadingFrom: local); defer { try? input.close() }
        while record.offset < record.total {
            try await context.checkpoint()
            guard JobJournal.Fingerprint(local) == fingerprint else { throw DropboxError.sourceChanged }
            try input.seek(toOffset: UInt64(record.offset))
            let bytes = try input.read(upToCount: Int(min(8 << 20, record.total - record.offset))) ?? Data()
            guard !bytes.isEmpty else { throw DropboxError.sourceChanged }
            record.phase = "appending"; record.proposedOffset = record.offset + Int64(bytes.count); try journal.save(record)
            _ = try await data(
                "files/upload_session/append_v2",
                arguments: [
                    "cursor": ["session_id": session, "offset": record.offset],
                    "content_hash": DropboxContentHash.hash(bytes),
                ], content: true, body: bytes)
            record.offset += Int64(bytes.count); record.phase = "prepared"; record.proposedOffset = nil
            try journal.save(record); context.progress(record.offset, record.total)
        }
        try await context.checkpoint()
        guard JobJournal.Fingerprint(local) == fingerprint, try DropboxContentHash.hash(local) == hash else { throw DropboxError.sourceChanged }
        var commit: [String: Any] = ["path": path, "autorename": false, "strict_conflict": true]
        commit["mode"] = expectedRevision.map { [".tag": "update", "update": $0] } ?? [".tag": "add"]
        record.phase = "committing"; try journal.save(record)
        do {
            let bytes = try await data(
                "files/upload_session/finish",
                arguments: [
                    "cursor": ["session_id": session, "offset": record.offset],
                    "commit": commit, "content_hash": DropboxContentHash.hash(Data()),
                ], content: true, body: Data())
            let result = try JSONDecoder().decode(DropboxItem.self, from: bytes)
            guard !result.isFolder, result.pathLower == path.lowercased(), result.size == record.total, result.contentHash == hash, result.rev != nil
            else { throw DropboxError.invalidResponse }
            record.result = result; record.phase = "done"; try journal.save(record)
            try await tokens.removeSecret(operationID); metadataCache.remember([result]); metadataCache.invalidate(); return result
        } catch {
            record.phase = (error as? DropboxError) == .conflict ? "conflict" : "uncertain"
            try journal.save(record); throw error
        }
    }
}
