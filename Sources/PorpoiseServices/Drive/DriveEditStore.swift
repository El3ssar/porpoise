import Foundation
import PorpoiseCore

public typealias DriveEditState = CloudEditState
public typealias DriveEditSession = CloudEditSession<DriveFile>
public typealias DriveEditStore = CloudEditSessionStore<DriveEditEngine>

public struct DriveEditEngine: CloudEditEngine, @unchecked Sendable {
    private weak var client: DriveClient?
    public let directory: URL
    init(client: DriveClient, directory: URL? = nil) {
        self.client = client; self.directory = directory ?? client.metadataCache.directory.appendingPathComponent("Edits")
    }
    public var unavailable: Error { DriveError.reconnect }
    public var sourceChanged: Error { DriveMutationError.sourceChanged }
    private func connected() throws -> DriveClient { guard let client else { throw unavailable }; return client }
    public func checkConnection() throws { if try connected().isOffline { throw DriveError.offline } }
    public func canUseCached(after error: Error) -> Bool { (error as? DriveError) == .offline }
    public func identity(_ file: DriveFile) -> String { file.id }
    public func revision(_ file: DriveFile) -> String? { file.headRevisionId }
    public func hash(_ url: URL) throws -> String { try DriveClient.md5(url) }
    public func uploadSource(_ operation: UUID) -> URL? { nil }
    public func prepare(_ file: DriveFile, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (DriveFile, URL) {
        let client = try connected()
        let fresh = try await client.file(file.id, resourceKey: file.resourceKey)
        guard fresh.operations.canWrite, fresh.operations.canDownload, !fresh.isGoogleDocument, let revision = fresh.headRevisionId,
            DriveLink.isValidID(revision)
        else { throw DriveError.permissionDenied }
        let name = try RemoteFS.localName(fresh.name)
        let folder = directory.appendingPathComponent(fresh.id).appendingPathComponent(revision).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        let offline = try await client.offlineCopies()
        let baseline = try await offline.fetch(
            client.contentSource.remoteItem(fresh), progress: { bytes, total in context.progress(bytes, total ?? bytes) })
        let verified = try await client.file(fresh.id)
        guard verified.headRevisionId == revision else { throw DriveMutationError.conflict }
        try cloudClone(baseline, to: url); return (fresh, url)
    }
    public func validate(_ file: DriveFile) async throws {
        let fresh = try await connected().file(file.id)
        guard let revision = file.headRevisionId, fresh.headRevisionId == revision else { throw DriveMutationError.conflict }
    }
    public func publish(_ local: URL, file: DriveFile, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws -> DriveFile {
        let client = try connected()
        let result: DriveFile
        if copyPath != nil {
            let current = try await client.file(file.id)
            result = try await client.upload(local, parentID: current.parents?.first ?? "root", name: FileFormat.noted(current.name, "edited on Mac"))
        } else {
            result = try await client.saveEdit(local, baseline: file)
        }
        if let offline = try? await client.offlineCopies() { _ = try? await offline.adopt(file: local, as: client.contentSource.remoteItem(result)) }
        return result
    }
    public func prepareReplacement(_ file: DriveFile) async throws -> DriveFile {
        let client = try connected(), current = try await client.file(file.id)
        guard let revision = current.headRevisionId, DriveLink.isValidID(revision) else { throw DriveMutationError.conflict }
        let url = client.baseURL.appendingPathComponent("files/\(current.id)/revisions/\(revision)")
        let (data, _) = try await client.mutationResponse(
            url, method: "PATCH", body: Data("{\"keepForever\":true}".utf8), headers: ["Content-Type": "application/json"])
        struct Revision: Decodable { let keepForever: Bool }
        guard try client.decode(Revision.self, data).keepForever else { throw DriveMutationError.conflict }
        return current
    }
    public func conflict(_ error: Error) -> Bool { (error as? DriveMutationError) == .conflict }
    public func remoteCopy(_ file: DriveFile, beside: URL) async -> URL? {
        guard let client, let remote = try? await client.file(file.id), let bytes = try? await client.download(remote).data,
            let name = RemoteParsing.localName(forRemote: "Remote-" + remote.name)
        else { return nil }
        let copy = beside.deletingLastPathComponent().appendingPathComponent(name)
        do { try bytes.write(to: copy, options: .atomic); return copy } catch { return nil }
    }
}
extension CloudEditSessionStore where Engine == DriveEditEngine {
    public init(client: DriveClient, directory: URL? = nil) { self.init(engine: DriveEditEngine(client: client, directory: directory)) }
    public func open(_ file: DriveFile, context: DriveTransferContext = .init()) async throws -> DriveEditSession {
        try await openSession(file, context: context)
    }
    public func save(_ id: UUID) async throws -> DriveFile { try await saveSession(id).file }
    public func keepBoth(_ id: UUID) async throws -> DriveFile { try await saveSession(id, copyPath: "copy").file }
    public func replaceWithMine(_ id: UUID) async throws -> DriveFile { try await replaceSession(id).file }
}

extension DriveClient {
    /// One conditional publication; no gap between revision validation and server-side replacement. Live Drive v3
    /// neither returns an ETag nor honours If-Match (W-122 probe: a stale one is accepted), so the media goes through
    /// v2, whose resource etag is refused with 412 once anything changed the file.
    func saveEdit(_ local: URL, baseline: DriveFile) async throws -> DriveFile {
        try await tokens.requireWriteScope()
        let fresh = try await file(baseline.id)
        struct Tagged: Decodable { let id: String?; let etag: String?; let headRevisionId: String?; let md5Checksum: String? }
        let (data, _) = try await mutationResponse(v2FileURL(baseline.id, fields: "etag,headRevisionId"))
        let tagged = try decode(Tagged.self, data)
        guard let revision = baseline.headRevisionId, fresh.headRevisionId == revision, tagged.headRevisionId == revision,
            let etag = tagged.etag, !etag.isEmpty, fresh.operations.canWrite, !fresh.isGoogleDocument
        else { throw DriveMutationError.conflict }
        do {
            let (result, _) = try await mutationResponse(
                v2FileURL(baseline.id, fields: "id,md5Checksum", upload: true), method: "PUT", body: Data(contentsOf: local),
                headers: ["Content-Type": fresh.mimeType, "If-Match": etag])
            let sent = try decode(Tagged.self, result)
            guard sent.id == baseline.id, sent.md5Checksum == (try Self.md5(local)) else { throw DriveError.invalidResponse }
        } catch DriveError.http(412) { throw DriveMutationError.conflict }
        let file = try await file(baseline.id)
        invalidateMutation(parents: file.parents ?? [])
        return file
    }
    /// The v2 resource for `id` (or its media upload) beside the v3 base URL.
    func v2FileURL(_ id: String, fields: String, upload: Bool = false) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let v2 = components.path.replacingOccurrences(of: "/drive/v3", with: "/drive/v2").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (upload ? "/upload/" : "/") + v2 + "/files/" + id
        components.queryItems =
            [URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "fields", value: fields)]
            + (upload ? [URLQueryItem(name: "uploadType", value: "media")] : [])
        return components.url!
    }
}
