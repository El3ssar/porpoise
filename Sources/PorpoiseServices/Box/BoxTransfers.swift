import CryptoKit
import Foundation
import PorpoiseCore

/// One uploaded part of a chunked session, as Box returns it and as the commit must name it.
public struct BoxPart: Codable, Equatable, Sendable {
    public var part_id: String
    public var offset: Int64
    public var size: Int64
    public var sha1: String?
}

public struct BoxOperation: CloudRangeDownloadRecord {
    public var version = 1
    public var operationID: UUID
    public var kind: String
    /// The item (download, replace, mutations) or the parent folder (a new upload, a new folder).
    public var path: String
    /// The new name (or parent and name), for operations that create, rename or move.
    public var destination: String?
    /// The precondition (the etag) for operations that change an existing item.
    public var revision: String?
    public var hash: String?
    public var total: Int64 = 0
    public var offset: Int64 = 0
    public var proposedOffset: Int64?
    public var phase = "prepared"
    /// A chunked session exists; its ID is in the credential store, never here.
    public var hasSession = false
    public var partSize: Int64?
    public var parts: [BoxPart]?
    public var localURL: URL?
    public var fingerprint: JobJournal.Fingerprint?
    public var downloadRanges: [CloudDownloadRange]?
    public var result: BoxItem?
    public init(operationID: UUID, kind: String, path: String) { self.operationID = operationID; self.kind = kind; self.path = path }
}

public enum BoxContentHash {
    public static func hash(_ url: URL) throws -> String { try CloudContentHash.sha1(url) }
    static func hash(_ bytes: Data) -> String { CloudContentHash.sha1(bytes) }
    /// The Digest header's value: base64 of the raw SHA-1. https://developer.box.com/guides/uploads/chunked/
    static func digest(hex: String) -> String? {
        var bytes = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return bytes.count == 20 ? "sha=" + bytes.base64EncodedString() : nil
    }
    static func digest(_ bytes: Data) -> String { "sha=" + Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString() }
}

extension BoxClient {
    /// The pre-authenticated download URL for `item` at its revision (the API answers with a redirect to it, which is
    /// read, not followed). It's a bearer capability: kept in memory only. https://developer.box.com/reference/get-files-id-content/
    func downloadLink(_ item: BoxItem, renew: Bool = false) async throws -> URL {
        let key = item.id + "\n" + (item.revision ?? "")
        if !renew, let cached = links.url(key) { return cached }
        let fresh = try await metadata(item.id, kind: .file)
        guard fresh.revision == item.revision, fresh.size == item.size, fresh.sha1 == item.sha1 else { throw BoxError.sourceChanged }
        for attempt in 0..<4 {
            let (data, response) = try await send(request(api(itemPath(item.id, .file) + "/content")), idempotent: true, client: unredirected)
            if response.statusCode == 202 {
                // Not ready to download yet (a file still being processed): Box says when to ask again.
                try await retryWait(CloudAuthorizedClient.delay(response, attempt: attempt)); continue
            }
            guard (300...399).contains(response.statusCode), let raw = response.value(forHTTPHeaderField: "Location"), let url = URL(string: raw),
                url.scheme == "https" || configuration.isAPI(url), url.user == nil
            else { try Self.check(data, response); throw BoxError.invalidResponse }
            links.keep(url, for: key); return url
        }
        throw BoxError.http(202)
    }
    /// Exact byte ranges for the shared range engine and the streaming proxy, from the download URL without the bearer.
    /// An expired URL is fetched again once; a changed revision never reads.
    func stream(_ item: BoxItem, range: Range<Int64>, receive: @escaping CloudRangeDownload.Receive) async throws -> HTTPURLResponse {
        guard item.canDownload, let total = item.size, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= total else {
            throw BoxError.invalidResponse
        }
        do {
            var link = try await downloadLink(item), renewed = false, attempt = 0
            while true {
                try Task.checkCancellation()
                var request = URLRequest(url: link)
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                var delivered = false
                let response = try await http.stream(request) { bytes, head in
                    guard head.statusCode == 206 else { return }
                    delivered = true; try await receive(bytes, head)
                }
                if response.statusCode == 206 { reached(nil); return response }
                if [401, 403, 404, 410].contains(response.statusCode), !renewed {
                    renewed = true; link = try await downloadLink(item, renew: true); continue
                }
                attempt += 1
                guard !delivered, [429, 500, 502, 503, 504].contains(response.statusCode), attempt < 4 else {
                    throw response.statusCode == 200 ? BoxError.invalidResponse : BoxError.http(response.statusCode)
                }
                try await Task.sleep(nanoseconds: UInt64(CloudAuthorizedClient.delay(response, attempt: attempt - 1) * 1_000_000_000))
            }
        } catch { reached(error); throw error }
    }
    public func readRange(_ item: BoxItem, range: Range<Int64>) async throws -> Data {
        guard range.count <= 1 << 20 else { throw BoxError.invalidResponse }
        var output = Data()
        let response = try await stream(item, range: range) { bytes, response in
            guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(item.size!)",
                output.count + bytes.count <= range.count
            else { throw BoxError.invalidResponse }
            output.append(bytes)
        }
        guard response.statusCode == 206, output.count == range.count else { throw BoxError.invalidResponse }; return output
    }
    public func streamingPreview(_ item: BoxItem, contentType: String) throws -> CloudStreamingPreview {
        guard item.canDownload, let size = item.size, item.revision != nil else { throw BoxError.invalidLocation }
        return try CloudStreamingPreview(size: size, contentType: contentType) { [weak self] range in
            guard let self else { throw CancellationError() }; return try await self.readRange(item, range: range)
        }
    }
    /// The caller publishes these verified staging bytes with its own no-overwrite destination policy.
    public func download(
        _ item: BoxItem, operationID: UUID = UUID(), maximumConnections: Int = 8, context: CloudTransferContext = .init()
    ) async throws -> URL {
        guard item.canDownload, let total = item.size, total >= 0, let revision = item.revision, let hash = item.sha1 else {
            throw BoxError.invalidResponse
        }
        do {
            let (partial, _) = try await CloudStagedDownload.run(
                journal: journal, operationID: operationID, context: context,
                transfer: .binary(total: total, connections: total < 32 << 20 ? 1 : maximumConnections, ranges: true),
                checksum: .sha1(hash),
                prepare: { existing in
                    var record = existing ?? BoxOperation(operationID: operationID, kind: "download", path: item.id)
                    guard record.kind == "download", record.phase != "cancelled", record.path == item.id,
                        record.revision == nil || record.revision == revision, record.hash == nil || record.hash == hash
                    else { throw BoxError.sourceChanged }
                    record.revision = revision; record.hash = hash; record.total = total; return record
                },
                fetch: { range, receive in
                    guard let range else { throw BoxError.invalidResponse }
                    return try await self.stream(item, range: range, receive: receive)
                },
                verify: {
                    let fresh = try await self.metadata(item.id, kind: .file)
                    guard fresh.revision == revision, fresh.sha1 == hash, fresh.size == total else { throw BoxError.sourceChanged }
                    return fresh
                }, finish: { $0.result = $1 })
            return partial
        } catch CloudTransferError.sourceChanged { throw BoxError.sourceChanged } catch CloudTransferError.invalidResponse {
            throw BoxError.invalidResponse
        }
    }

    /// Uploads `local` as a new item `name` in `parentID`, or as a new version of `replacing` at its etag (If-Match).
    /// Below `chunkedThreshold` it is one request; above, a chunked session whose ID stays in the credential store and
    /// whose confirmed parts are journaled. A new name never replaces what's there (Box refuses it with 409), and a lost
    /// final response is never sent again. https://developer.box.com/guides/uploads/
    public func upload(
        _ local: URL, to parentID: String, named name: String, replacing: BoxItem? = nil, operationID: UUID = UUID(),
        context: CloudTransferContext = .init()
    ) async throws -> BoxItem {
        try Self.validateName(name)
        let parentID = parentID.isEmpty ? BoxItem.rootID : parentID
        guard let fingerprint = JobJournal.Fingerprint(local), (try? local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw BoxError.invalidLocation }
        if let replacing, replacing.etag == nil || replacing.kind != .file { throw BoxError.invalidLocation }
        try journal.claim(operationID); defer { journal.release(operationID) }
        let hash = try BoxContentHash.hash(local)
        let target = replacing?.id ?? parentID
        let previous = try journal.load(operationID)
        var record = previous ?? BoxOperation(operationID: operationID, kind: replacing == nil ? "upload" : "replace", path: target)
        if previous == nil { record.revision = replacing?.etag; record.destination = name }
        guard record.kind == (replacing == nil ? "upload" : "replace"), record.path == target, record.destination == name,
            record.revision == replacing?.etag, record.fingerprint == nil || record.fingerprint == fingerprint,
            record.hash == nil || record.hash == hash
        else { throw BoxError.sourceChanged }
        if record.phase == "done", let result = record.result { return result }
        if record.phase == "conflict" { throw BoxError.conflict }
        guard record.phase != "committing", record.phase != "uncertain" else { throw BoxError.uncertain }
        record.localURL = local; record.fingerprint = fingerprint; record.total = fingerprint.size; record.hash = hash
        try journal.save(record); try await context.checkpoint()
        let precondition = replacing?.etag.map { ["If-Match": $0] } ?? [:]

        func finish(_ attempt: () async throws -> (Data, HTTPURLResponse)) async throws -> BoxItem {
            record.phase = "committing"; try journal.save(record)
            do {
                var (data, response) = try await attempt()
                // A committed session still assembling its parts answers 202: asking again is how to wait for it.
                var waits = 0
                while response.statusCode == 202, waits < 30 {
                    try await retryWait(CloudAuthorizedClient.delay(response, attempt: min(waits, 2))); waits += 1
                    (data, response) = try await attempt()
                }
                try Self.check(data, response)
                guard [200, 201].contains(response.statusCode) else { throw BoxError.invalidResponse }
                struct Entries: Decodable { var entries: [BoxItem] }
                guard let result = try JSONDecoder().decode(Entries.self, from: data).entries.first else { throw BoxError.invalidResponse }
                guard result.kind == .file, result.size == record.total, result.sha1 == nil || result.sha1 == hash,
                    replacing == nil ? (result.parentID == nil || result.parentID == parentID) : result.id == replacing?.id
                else { throw BoxError.invalidResponse }
                record.result = result; record.phase = "done"; try journal.save(record)
                if record.hasSession { try await tokens.removeSecret(operationID) }
                metadataCache.remember([result]); metadataCache.invalidate(); return result
            } catch {
                record.phase = (error as? BoxError) == .conflict ? "conflict" : "uncertain"
                try journal.save(record); throw error
            }
        }
        if record.total < configuration.chunkedThreshold {
            guard try BoxContentHash.hash(local) == hash, JobJournal.Fingerprint(local) == fingerprint else { throw BoxError.sourceChanged }
            let bytes = try Data(contentsOf: local)
            let attributes: [String: Any] = replacing == nil ? ["name": name, "parent": ["id": parentID]] : [:]
            let boundary = "porpoise-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n".utf8)
            body += try JSONSerialization.data(withJSONObject: attributes)
            body += Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\n".utf8)
            body += Data("Content-Type: application/octet-stream\r\n\r\n".utf8) + bytes + Data("\r\n--\(boundary)--\r\n".utf8)
            let path = replacing.map { itemPath($0.id, .file) + "/content" } ?? "files/content"
            // Content-MD5 carries the SHA-1, as Box defines it: a damaged body is refused, not stored.
            var post = try request(api(path, upload: true), method: "POST", headers: precondition.merging(["Content-MD5": hash]) { a, _ in a })
            post.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type"); post.httpBody = body
            let result = try await finish { try await send(post, idempotent: false) }
            context.progress(record.total, record.total); return result
        }
        for _ in 0..<2 {
            if !record.hasSession {
                struct Session: Decodable { var id: String; var part_size: Int64 }
                let path = replacing.map { itemPath($0.id, .file) + "/upload_sessions" } ?? "files/upload_sessions"
                var json: [String: Any] = ["file_size": record.total]
                if replacing == nil { json["folder_id"] = parentID; json["file_name"] = name }
                let (data, _): (Data, HTTPURLResponse)
                do {
                    (data, _) = try await send(request(api(path, upload: true), method: "POST", json: json), idempotent: false)
                } catch BoxError.conflict {
                    record.phase = "conflict"; try journal.save(record); throw BoxError.conflict
                }
                let session = try JSONDecoder().decode(Session.self, from: data)
                guard !session.id.isEmpty, session.part_size > 0 else { throw BoxError.invalidResponse }
                try await tokens.saveSecret(session.id, id: operationID)
                record.hasSession = true; record.partSize = session.part_size; record.parts = []; record.offset = 0
                record.proposedOffset = nil; record.phase = "prepared"; try journal.save(record)
            }
            guard let sessionID = try await tokens.secret(operationID), let partSize = record.partSize else { throw BoxError.uncertain }
            let sessionPath = "files/upload_sessions/" + boxEscape(sessionID)
            if record.phase == "appending" {
                // A part's answer was lost: the session says which parts it has.
                struct Parts: Decodable { var entries: [BoxPart] }
                let data: Data
                do {
                    (data, _) = try await send(
                        request(api(sessionPath + "/parts", query: [.init(name: "limit", value: "1000")], upload: true)), idempotent: true)
                } catch BoxError.notFound {
                    try await tokens.removeSecret(operationID); record.hasSession = false; record.offset = 0; record.parts = nil
                    record.phase = "prepared"; try journal.save(record); continue
                }
                let listed = try JSONDecoder().decode(Parts.self, from: data).entries
                if let part = listed.first(where: { $0.offset == record.offset }), part.offset + part.size == record.proposedOffset {
                    record.parts = (record.parts ?? []) + [part]; record.offset += part.size
                }
                record.phase = "prepared"; record.proposedOffset = nil; try journal.save(record)
            }
            let input = try FileHandle(forReadingFrom: local); defer { try? input.close() }
            var expired = false
            while record.offset < record.total {
                try await context.checkpoint()
                guard JobJournal.Fingerprint(local) == fingerprint else { throw BoxError.sourceChanged }
                try input.seek(toOffset: UInt64(record.offset))
                let bytes = try input.read(upToCount: Int(min(partSize, record.total - record.offset))) ?? Data()
                guard !bytes.isEmpty else { throw BoxError.sourceChanged }
                let end = record.offset + Int64(bytes.count)
                var put = try request(
                    api(sessionPath, upload: true), method: "PUT",
                    headers: [
                        "Content-Range": "bytes \(record.offset)-\(end - 1)/\(record.total)", "Digest": BoxContentHash.digest(bytes),
                        "Content-Type": "application/octet-stream",
                    ])
                put.httpBody = bytes
                record.phase = "appending"; record.proposedOffset = end; try journal.save(record)
                let data: Data
                do { (data, _) = try await send(put, idempotent: false) } catch BoxError.notFound { expired = true; break }
                struct Uploaded: Decodable { var part: BoxPart }
                let part = try JSONDecoder().decode(Uploaded.self, from: data).part
                guard part.offset == record.offset, part.size == Int64(bytes.count) else { throw BoxError.invalidResponse }
                record.parts = (record.parts ?? []) + [part]; record.offset = end; record.phase = "prepared"; record.proposedOffset = nil
                try journal.save(record); context.progress(record.offset, record.total)
            }
            if expired {
                // The session expired or was aborted: a new one, from the start.
                try await tokens.removeSecret(operationID); record.hasSession = false; record.offset = 0; record.parts = nil
                record.phase = "prepared"; try journal.save(record); continue
            }
            guard try BoxContentHash.hash(local) == hash, let digest = BoxContentHash.digest(hex: hash) else { throw BoxError.sourceChanged }
            let parts = (record.parts ?? []).map {
                ["part_id": $0.part_id, "offset": $0.offset, "size": $0.size, "sha1": $0.sha1 ?? ""] as [String: Any]
            }
            let commit = try request(
                api(sessionPath + "/commit", upload: true), method: "POST", json: ["parts": parts],
                headers: precondition.merging(["Digest": digest]) { a, _ in a })
            return try await finish { try await send(commit, idempotent: false) }
        }
        throw BoxError.uncertain
    }
}

/// Download URLs by item and revision, for a few minutes. Memory only.
final class BoxLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: (URL, Date)] = [:]
    func url(_ key: String) -> URL? { lock.withLock { links[key].flatMap { $0.1 > Date() ? $0.0 : nil } } }
    func keep(_ url: URL, for key: String) {
        lock.withLock {
            links = links.filter { $0.value.1 > Date() }; links[key] = (url, Date().addingTimeInterval(600))
        }
    }
}

extension BoxOperation: CloudStagedDownloadRecord {
    var stagedURL: URL? {
        get { localURL }
        set { localURL = newValue }
    }
    var stagedComplete: Bool {
        get { phase == "done" }
        set { if newValue { phase = "done" } }
    }
    mutating func beginDownload() {}
}
