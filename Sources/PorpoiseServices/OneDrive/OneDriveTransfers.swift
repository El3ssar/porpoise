import Foundation
import PorpoiseCore

public struct OneDriveOperation: CloudRangeDownloadRecord {
    public var version = 1
    public var operationID: UUID
    public var kind: String
    /// The item (download, replace, mutations) or the parent folder (a new upload, a new folder).
    public var path: String
    /// The new name, for operations that create or rename.
    public var destination: String?
    public var revision: String?
    public var hash: String?
    public var total: Int64 = 0
    public var offset: Int64 = 0
    public var proposedOffset: Int64?
    public var phase = "prepared"
    public var hasSession = false
    /// A copy's monitor: an unauthenticated status URL, so a copy interrupted while it runs is followed, not repeated.
    public var monitor: URL?
    public var localURL: URL?
    public var fingerprint: JobJournal.Fingerprint?
    public var downloadRanges: [CloudDownloadRange]?
    public var result: OneDriveItem?
    public init(operationID: UUID, kind: String, path: String) { self.operationID = operationID; self.kind = kind; self.path = path }
}

public enum OneDriveContentHash {
    public static func hash(_ url: URL) throws -> String { try CloudContentHash.quickXor(url) }
    static func hash(_ bytes: Data) -> String { CloudContentHash.quickXor(bytes) }
}

/// Upload-session chunks: a multiple of 320 KiB, as Graph requires, and well under its 60 MiB limit.
/// https://learn.microsoft.com/graph/api/driveitem-createuploadsession
let oneDriveChunk = 32 * 320 * 1024

extension OneDriveClient {
    /// A pre-authenticated download URL for `item` at its revision. It's a bearer capability: kept in memory only.
    func downloadLink(_ item: OneDriveItem, renew: Bool = false) async throws -> URL {
        let key = item.id + "\n" + (item.revision ?? "")
        if !renew, let cached = links.url(key) { return cached }
        struct Linked: Decodable {
            var url: String?
            enum CodingKeys: String, CodingKey { case url = "@microsoft.graph.downloadUrl" }
        }
        let (data, _) = try await send(request(graph(itemPath(item.id))), idempotent: true)
        let fresh = try JSONDecoder().decode(OneDriveItem.self, from: data)
        guard fresh.id == item.id, fresh.revision == item.revision, fresh.size == item.size, fresh.quickXorHash == item.quickXorHash else {
            throw OneDriveError.sourceChanged
        }
        guard let raw = try JSONDecoder().decode(Linked.self, from: data).url, let url = URL(string: raw),
            url.scheme == "https" || configuration.isGraph(url), url.user == nil
        else { throw OneDriveError.invalidResponse }
        links.keep(url, for: key); return url
    }
    /// Exact byte ranges for the shared range engine and the streaming proxy, from the download URL without the bearer.
    /// An expired URL is fetched again once; a changed revision never reads.
    func stream(_ item: OneDriveItem, range: Range<Int64>, receive: @escaping CloudRangeDownload.Receive) async throws -> HTTPURLResponse {
        guard item.canDownload, let total = item.size, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= total else {
            throw OneDriveError.invalidResponse
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
                    throw response.statusCode == 200 ? OneDriveError.invalidResponse : OneDriveError.http(response.statusCode)
                }
                try await Task.sleep(nanoseconds: UInt64(CloudAuthorizedClient.delay(response, attempt: attempt - 1) * 1_000_000_000))
            }
        } catch { reached(error); throw error }
    }
    public func readRange(_ item: OneDriveItem, range: Range<Int64>) async throws -> Data {
        guard range.count <= 1 << 20 else { throw OneDriveError.invalidResponse }
        var output = Data()
        let response = try await stream(item, range: range) { bytes, response in
            guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(item.size!)",
                output.count + bytes.count <= range.count
            else { throw OneDriveError.invalidResponse }
            output.append(bytes)
        }
        guard response.statusCode == 206, output.count == range.count else { throw OneDriveError.invalidResponse }; return output
    }
    public func streamingPreview(_ item: OneDriveItem, contentType: String) throws -> CloudStreamingPreview {
        guard item.canDownload, let size = item.size, item.revision != nil else { throw OneDriveError.invalidLocation }
        return try CloudStreamingPreview(size: size, contentType: contentType) { [weak self] range in
            guard let self else { throw CancellationError() }; return try await self.readRange(item, range: range)
        }
    }
    /// The caller publishes these verified staging bytes with its own no-overwrite destination policy.
    public func download(
        _ item: OneDriveItem, operationID: UUID = UUID(), maximumConnections: Int = 8, context: CloudTransferContext = .init()
    ) async throws -> URL {
        guard item.canDownload, let total = item.size, total >= 0, let revision = item.revision, let hash = item.quickXorHash else {
            throw OneDriveError.invalidResponse
        }
        do {
            let (partial, _) = try await CloudStagedDownload.run(
                journal: journal, operationID: operationID, context: context,
                transfer: .binary(total: total, connections: total < 32 << 20 ? 1 : maximumConnections, ranges: true),
                checksum: .quickXor(hash),
                prepare: { existing in
                    var record = existing ?? OneDriveOperation(operationID: operationID, kind: "download", path: item.id)
                    guard record.kind == "download", record.phase != "cancelled", record.path == item.id,
                        record.revision == nil || record.revision == revision, record.hash == nil || record.hash == hash
                    else { throw OneDriveError.sourceChanged }
                    record.revision = revision; record.hash = hash; record.total = total; return record
                },
                fetch: { range, receive in
                    guard let range else { throw OneDriveError.invalidResponse }
                    return try await self.stream(item, range: range, receive: receive)
                },
                verify: {
                    let fresh = try await self.metadata(item.id)
                    guard fresh.revision == revision, fresh.quickXorHash == hash, fresh.size == total else { throw OneDriveError.sourceChanged }
                    return fresh
                }, finish: { $0.result = $1 })
            return partial
        } catch CloudTransferError.sourceChanged { throw OneDriveError.sourceChanged } catch CloudTransferError.invalidResponse {
            throw OneDriveError.invalidResponse
        }
    }

    /// Uploads `local` as a new item `name` in `parentID`, or over `replacing` at its revision (If-Match). The session's
    /// upload URL is a secret: it stays in the credential store. A new name never replaces what's there
    /// (conflictBehavior=fail), and a lost final response is never sent again.
    public func upload(
        _ local: URL, to parentID: String, named name: String, replacing: OneDriveItem? = nil, operationID: UUID = UUID(),
        context: CloudTransferContext = .init()
    ) async throws -> OneDriveItem {
        try Self.validateName(name)
        guard let fingerprint = JobJournal.Fingerprint(local), (try? local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw OneDriveError.invalidLocation }
        if let replacing, replacing.revision == nil || replacing.isFolder { throw OneDriveError.invalidLocation }
        try journal.claim(operationID); defer { journal.release(operationID) }
        let hash = try OneDriveContentHash.hash(local)
        let target = replacing?.id ?? parentID
        let previous = try journal.load(operationID)
        var record = previous ?? OneDriveOperation(operationID: operationID, kind: replacing == nil ? "upload" : "replace", path: target)
        if previous == nil { record.revision = replacing?.revision; record.destination = name }
        guard record.kind == (replacing == nil ? "upload" : "replace"), record.path == target, record.destination == name,
            record.revision == replacing?.revision, record.fingerprint == nil || record.fingerprint == fingerprint,
            record.hash == nil || record.hash == hash
        else { throw OneDriveError.sourceChanged }
        if record.phase == "done", let result = record.result { return result }
        if record.phase == "conflict" { throw OneDriveError.conflict }
        guard record.phase != "committing", record.phase != "uncertain" else { throw OneDriveError.uncertain }
        record.localURL = local; record.fingerprint = fingerprint; record.total = fingerprint.size; record.hash = hash
        try journal.save(record); try await context.checkpoint()
        let conflict = ["@microsoft.graph.conflictBehavior": replacing == nil ? "fail" : "replace"]
        let precondition = replacing?.revision.map { ["If-Match": $0] } ?? [:]

        func finish(_ attempt: () async throws -> (Data, HTTPURLResponse)) async throws -> OneDriveItem {
            record.phase = "committing"; try journal.save(record)
            do {
                let (data, response) = try await attempt()
                try Self.check(data, response)
                guard [200, 201].contains(response.statusCode) else { throw OneDriveError.invalidResponse }
                var result = try JSONDecoder().decode(OneDriveItem.self, from: data)
                if result.driveID == nil { result.driveID = driveID }
                guard !result.isFolder, result.size == record.total, result.quickXorHash == nil || result.quickXorHash == hash,
                    replacing == nil ? (result.parentID == nil || result.parentID == parentID || parentID.isEmpty) : result.id == replacing?.id
                else { throw OneDriveError.invalidResponse }
                record.result = result; record.phase = "done"; try journal.save(record)
                if record.hasSession { try await tokens.removeSecret(operationID) }
                metadataCache.remember([result]); metadataCache.invalidate(); return result
            } catch {
                record.phase = (error as? OneDriveError) == .conflict ? "conflict" : "uncertain"
                try journal.save(record); throw error
            }
        }
        // Graph refuses empty upload sessions: an empty file is one PUT.
        if record.total == 0 {
            let path = replacing.map { itemPath($0.id) + "/content" } ?? itemPath(parentID) + ":/" + oneDriveEscape(name) + ":/content"
            var put = try request(
                graph(path, query: replacing == nil ? [.init(name: "@microsoft.graph.conflictBehavior", value: "fail")] : []), method: "PUT",
                headers: precondition)
            put.httpBody = Data(); put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            return try await finish { try await send(put, idempotent: false) }
        }
        for _ in 0..<2 {
            if !record.hasSession {
                struct Session: Decodable { var uploadUrl: String }
                let path =
                    replacing.map { itemPath($0.id) + "/createUploadSession" }
                    ?? itemPath(parentID) + ":/" + oneDriveEscape(name) + ":/createUploadSession"
                let (data, _) = try await send(
                    request(graph(path), method: "POST", json: ["item": conflict], headers: precondition), idempotent: false)
                let session = try JSONDecoder().decode(Session.self, from: data)
                guard let url = URL(string: session.uploadUrl), url.scheme == "https" || configuration.isGraph(url) else {
                    throw OneDriveError.invalidResponse
                }
                try await tokens.saveSecret(session.uploadUrl, id: operationID)
                record.hasSession = true; record.offset = 0; record.proposedOffset = nil; record.phase = "prepared"; try journal.save(record)
            }
            guard let raw = try await tokens.secret(operationID), let session = URL(string: raw) else { throw OneDriveError.uncertain }
            if record.phase == "appending" {
                // A chunk's answer was lost: the session says what it has.
                struct Status: Decodable { var nextExpectedRanges: [String]? }
                let (data, response) = try await http.response(URLRequest(url: session))
                if response.statusCode == 404 {
                    try await tokens.removeSecret(operationID); record.hasSession = false; continue
                }
                try Self.check(data, response)
                let next = try JSONDecoder().decode(Status.self, from: data).nextExpectedRanges?.first
                guard let start = next?.split(separator: "-").first.flatMap({ Int64($0) }), start >= record.offset,
                    start <= (record.proposedOffset ?? record.offset), start < record.total
                else { throw OneDriveError.invalidResponse }
                record.offset = start; record.phase = "prepared"; record.proposedOffset = nil; try journal.save(record)
            }
            let input = try FileHandle(forReadingFrom: local); defer { try? input.close() }
            while true {
                try await context.checkpoint()
                guard JobJournal.Fingerprint(local) == fingerprint else { throw OneDriveError.sourceChanged }
                try input.seek(toOffset: UInt64(record.offset))
                let bytes = try input.read(upToCount: Int(min(Int64(oneDriveChunk), record.total - record.offset))) ?? Data()
                guard !bytes.isEmpty else { throw OneDriveError.sourceChanged }
                let end = record.offset + Int64(bytes.count)
                var put = URLRequest(url: session); put.httpMethod = "PUT"; put.httpBody = bytes
                put.setValue("bytes \(record.offset)-\(end - 1)/\(record.total)", forHTTPHeaderField: "Content-Range")
                if end == record.total {
                    guard try OneDriveContentHash.hash(local) == hash else { throw OneDriveError.sourceChanged }
                    return try await finish { try await http.response(put) }
                }
                record.phase = "appending"; record.proposedOffset = end; try journal.save(record)
                let (data, response) = try await http.response(put)
                if response.statusCode == 404 { break }  // the session expired: a new one, from the start
                try Self.check(data, response)
                guard response.statusCode == 202 else { throw OneDriveError.invalidResponse }
                record.offset = end; record.phase = "prepared"; record.proposedOffset = nil
                try journal.save(record); context.progress(record.offset, record.total)
            }
            try await tokens.removeSecret(operationID); record.hasSession = false; record.offset = 0; record.phase = "prepared"
            try journal.save(record)
        }
        throw OneDriveError.uncertain
    }
}

/// Download URLs by item and revision, for a few minutes (Graph's last about an hour). Memory only.
final class OneDriveLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: (URL, Date)] = [:]
    func url(_ key: String) -> URL? { lock.withLock { links[key].flatMap { $0.1 > Date() ? $0.0 : nil } } }
    func keep(_ url: URL, for key: String) {
        lock.withLock {
            links = links.filter { $0.value.1 > Date() }; links[key] = (url, Date().addingTimeInterval(600))
        }
    }
}

extension OneDriveOperation: CloudStagedDownloadRecord {
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
