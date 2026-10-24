import Foundation
import PorpoiseCore

struct S3Operation: CloudStagedDownloadRecord {
    var version = 1
    var operationID: UUID
    var kind: String
    var key: String
    var revision: String = ""
    var localURL: URL?
    var sourceFingerprint: JobJournal.Fingerprint?
    var total: Int64 = 0
    var partSize = 8 << 20
    var uploadID: String?
    var completing = false
    var parts: [String: String] = [:]
    var offset: Int64 = 0
    var downloadRanges: [CloudDownloadRange]?
    var fingerprint: JobJournal.Fingerprint?
    var stagedURL: URL?
    var stagedComplete = false
    var temporary: Bool?
    var started: Date?
    mutating func beginDownload() {}
}

extension S3Client {
    /// Immutable revision reads and durable staging are owned by the shared download engine.
    func download(_ object: S3Object, operationID: UUID = UUID(), context: CloudTransferContext = .init()) async throws -> URL {
        let (partial, _) = try await CloudStagedDownload.run(
            journal: journal, operationID: operationID, context: context,
            transfer: .binary(total: object.size, connections: object.size < 32 << 20 ? 1 : 4, ranges: true), checksum: nil,
            prepare: { existing in
                var record = existing ?? S3Operation(operationID: operationID, kind: "download", key: object.key)
                guard record.kind == "download", record.key == object.key, record.revision.isEmpty || record.revision == object.etag else {
                    throw S3Error.changed
                }
                record.revision = object.etag; record.total = object.size; return record
            },
            fetch: { range, receive in
                guard let range else { throw S3Error.invalidResponse }
                let request = try self.request(
                    "GET", key: object.key,
                    headers: [
                        "If-Match": object.etag,
                        "Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                    ])
                return try await self.authorized.send(request, idempotent: true, receive: receive).1
            },
            verify: {
                let fresh = try await self.head(object.key)
                guard fresh.etag == object.etag, fresh.size == object.size else { throw S3Error.changed }; return fresh
            }, finish: { _, _ in })
        return partial
    }
    /// Part ETags are checkpointed only after server acknowledgement. Retrying an uncheckpointed part replaces
    /// that part number. No session secrets are needed: every request is signed anew with Keychain credentials.
    /// Opaque operations cannot be resumed by a later job: abort their parts on failure or cancellation.
    public func upload(_ local: URL, key: String, context: CloudTransferContext = .init()) async throws {
        try await discardStaleUploads()
        let operation = UUID()
        var record = S3Operation(operationID: operation, kind: "upload", key: key)
        record.temporary = true; record.started = Date()
        try journal.save(record)
        do { try await upload(local, key: key, operationID: operation, context: context) } catch {
            // Cleanup must run even when the transfer's task has already been cancelled. Failed cleanup remains journalled.
            _ = await Task.detached { try? await self.abortUpload(operationID: operation) }.value
            throw error
        }
    }
    /// An explicit operation identifier is the caller's durable resume contract. Failure retains acknowledged parts.
    public func upload(_ local: URL, key: String, operationID: UUID, context: CloudTransferContext = .init()) async throws {
        guard !key.isEmpty, !key.hasSuffix("/"), let fingerprint = JobJournal.Fingerprint(local), fingerprint.size <= 5 * 1024 * 1024 * 1024 * 1024,
            (try local.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
        else { throw S3Error.invalidLocation }
        try migrateUpload(operationID, from: legacyJournal)
        try journal.claim(operationID); defer { journal.release(operationID) }
        var record = try journal.load(operationID) ?? S3Operation(operationID: operationID, kind: "upload", key: key)
        guard record.kind == "upload", record.key == key, record.localURL == nil || record.localURL == local,
            record.sourceFingerprint == nil || record.sourceFingerprint == fingerprint
        else { throw S3Error.changed }
        record.localURL = local; record.sourceFingerprint = fingerprint; record.total = fingerprint.size
        record.partSize = max(8 << 20, Int((record.total + 9999) / 10000))
        try journal.save(record); try await context.checkpoint()
        if record.completing {
            do {
                let object = try await head(key)
                if object.operation == operationID.uuidString, object.size == record.total {
                    try journal.remove(operationID); context.progress(record.total, record.total); return
                }
            } catch S3Error.service(404, _) {}
        }
        if record.total < 8 << 20 {
            let bytes = try Data(contentsOf: local)
            guard JobJournal.Fingerprint(local) == fingerprint else { throw S3Error.changed }
            _ = try await send("PUT", key: key, body: bytes); context.progress(record.total, record.total)
            try journal.remove(operationID); return
        }
        if record.uploadID == nil {
            let xml = try S3XML.parse(
                await send(
                    "POST", key: key, query: ["uploads": ""], headers: ["x-amz-meta-porpoise-operation": operationID.uuidString], idempotent: false
                ).0)
            guard let id = xml.first("UploadId"), !id.isEmpty else { throw S3Error.invalidResponse }
            record.uploadID = id; try journal.save(record)
        }
        let id = record.uploadID!, handle = try FileHandle(forReadingFrom: local); defer { try? handle.close() }
        let count = Int((record.total + Int64(record.partSize) - 1) / Int64(record.partSize))
        for number in 1...count {
            try await context.checkpoint()
            guard JobJournal.Fingerprint(local) == fingerprint else { throw S3Error.changed }
            if record.parts[String(number)] != nil { continue }
            let start = Int64(number - 1) * Int64(record.partSize), length = Int(min(Int64(record.partSize), record.total - start))
            try handle.seek(toOffset: UInt64(start))
            guard let bytes = try handle.read(upToCount: length), bytes.count == length else { throw S3Error.changed }
            let (_, response) = try await send("PUT", key: key, query: ["uploadId": id, "partNumber": String(number)], body: bytes)
            guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw S3Error.invalidResponse }
            record.parts[String(number)] = etag; try journal.save(record); context.progress(start + Int64(length), record.total)
        }
        guard JobJournal.Fingerprint(local) == fingerprint else { throw S3Error.changed }
        let parts = (1...count).map { "<Part><PartNumber>\($0)</PartNumber><ETag>\(S3XML.escape(record.parts[String($0)]!))</ETag></Part>" }.joined()
        record.completing = true; try journal.save(record)
        let xml = try S3XML.parse(
            await send(
                "POST", key: key, query: ["uploadId": id], headers: ["Content-Type": "application/xml"],
                body: Data("<CompleteMultipartUpload>\(parts)</CompleteMultipartUpload>".utf8), idempotent: false
            ).0)
        guard xml.first("ETag") != nil, xml.first("Code") == nil else { throw S3Error.invalidResponse }
        try journal.remove(operationID); context.progress(record.total, record.total)
    }
    /// Only abandoned opaque operations expire. Explicit caller-owned resume records are never swept.
    func discardStaleUploads(now: Date = Date()) async throws {
        for record in try journal.all() where record.kind == "upload" && record.temporary == true {
            guard let started = record.started, now.timeIntervalSince(started) > 86400 else { continue }
            do { try await abortUpload(operationID: record.operationID) } catch CloudJournalError.busy { continue }
        }
    }
    /// Preserve explicit resume identifiers when upgrading from the old disposable journal location.
    /// Download partials stay at their original location; only metadata-only upload records migrate.
    func migrateUpload(_ operation: UUID, from legacy: CloudJournal<S3Operation>?) throws {
        guard try journal.load(operation) == nil, let legacy, let record = try legacy.load(operation), record.kind == "upload" else { return }
        try journal.save(record)
        try legacy.remove(operation)
    }
    public func abortUpload(operationID: UUID) async throws {
        try migrateUpload(operationID, from: legacyJournal)
        try journal.claim(operationID); defer { journal.release(operationID) }
        guard let record = try journal.load(operationID), record.kind == "upload" else { throw S3Error.invalidLocation }
        if let id = record.uploadID {
            do { _ = try await send("DELETE", key: record.key, query: ["uploadId": id]) } catch S3Error.service(404, _) {}
        }
        try journal.remove(operationID)
    }
}

extension S3Client {
    /// Large objects remain on the service: each part copies an exact source revision and byte range.
    func multipartCopy(_ object: S3Object, to key: String, sourceHeaders: [String: String], revision: String?, context: CloudTransferContext)
        async throws
    {
        let initiation = try S3XML.parse(await send("POST", key: key, query: ["uploads": ""], idempotent: false).0)
        guard let id = initiation.first("UploadId"), !id.isEmpty else { throw S3Error.invalidResponse }
        do {
            let width = max(copyPartSize, (object.size + 9999) / 10000)
            guard width <= 5 * 1024 * 1024 * 1024 else { throw S3Error.invalidLocation }
            var offset: Int64 = 0, parts: [String] = [], number = 1
            while offset < object.size {
                try await context.checkpoint()
                let end = min(object.size, offset + width)
                var headers = sourceHeaders; headers["x-amz-copy-source-range"] = "bytes=\(offset)-\(end - 1)"
                let xml = try S3XML.parse(await send("PUT", key: key, query: ["uploadId": id, "partNumber": String(number)], headers: headers).0)
                guard let etag = xml.first("ETag"), xml.first("Code") == nil else { throw S3Error.invalidResponse }
                parts.append("<Part><PartNumber>\(number)</PartNumber><ETag>\(S3XML.escape(etag))</ETag></Part>")
                offset = end; number += 1; context.progress(offset, object.size)
            }
            try await context.checkpoint()
            let fresh = try await head(object.key)
            guard fresh.etag == object.etag, fresh.size == object.size else { throw S3Error.changed }
            // R2 documents destination conditions specifically for CopyObject. Multipart completion uses S3's
            // standard conditional header; providers that reject it must never fall back to unconditional completion.
            let completionCondition = revision == nil ? "If-None-Match" : "If-Match"
            let xml = try S3XML.parse(
                await send(
                    "POST", key: key, query: ["uploadId": id],
                    headers: [completionCondition: revision ?? "*", "Content-Type": "application/xml"],
                    body: Data(("<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>").utf8), idempotent: false
                ).0)
            guard xml.first("ETag") != nil, xml.first("Code") == nil else { throw S3Error.invalidResponse }
        } catch {
            _ = try? await send("DELETE", key: key, query: ["uploadId": id]); throw error
        }
    }
}
