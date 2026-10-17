import Foundation
import PorpoiseCore

public enum DriveEditState: Codable, Sendable, Equatable {
    case editing, saving, saved, conflict, unsent(String)
}

public struct DriveEditSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let localURL: URL
    public var file: DriveFile
    public var state: DriveEditState = .editing
    public var conflictURL: URL?
    var sentMD5: String
}

/// Durable editable bytes never enter the disposable media LRU. Hash comparison discovers saves after a crash.
public actor DriveEditStore {
    public static let changed = Notification.Name("PorpoiseDriveEditChanged")
    private weak var client: DriveClient?
    private let directory: URL
    private var sessions: [UUID: DriveEditSession] = [:]
    private var saving: Set<UUID> = []
    private var openSessions: Set<UUID> = []
    public init(client: DriveClient, directory: URL? = nil) {
        self.client = client
        self.directory = directory ?? client.metadataCache.directory.appendingPathComponent("Edits")
        if let files = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), var session = try? JSONDecoder().decode(DriveEditSession.self, from: data),
                    session.localURL.standardizedFileURL.path.hasPrefix(self.directory.standardizedFileURL.path + "/")
                {
                    if session.state != .conflict, (try? DriveClient.md5(session.localURL)) != session.sentMD5 {
                        session.state = .unsent("Saved changes have not reached Google Drive.")
                    }
                    sessions[session.id] = session
                }
            }
        }
    }
    public func session(_ id: UUID) -> DriveEditSession? { sessions[id] }
    public func pending() -> [DriveEditSession] {
        sessions.values.filter { (try? DriveClient.md5($0.localURL)) != $0.sentMD5 }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func holdsCopy(_ id: String) -> Bool {
        sessions.values.contains { $0.file.id == id && (openSessions.contains($0.id) || (try? DriveClient.md5($0.localURL)) != $0.sentMD5) }
    }
    public func releaseCopy(_ id: UUID) { openSessions.remove(id) }
    public func cachedSession(_ file: DriveFile) -> DriveEditSession? {
        sessions.values.first {
            $0.file.id == file.id && ($0.file.headRevisionId == file.headRevisionId || $0.state != .editing)
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }
    }

    public func open(_ file: DriveFile, context: DriveTransferContext = .init()) async throws -> DriveEditSession {
        guard let client else { throw DriveError.reconnect }
        if let pending = pending().first(where: { $0.file.id == file.id }) { openSessions.insert(pending.id); return pending }
        if client.isOffline {
            guard let existing = sessions.values.first(where: { $0.file.id == file.id }),
                FileManager.default.fileExists(atPath: existing.localURL.path)
            else { throw DriveError.offline }
            openSessions.insert(existing.id); return existing
        }
        let fresh = try await client.file(file.id, resourceKey: file.resourceKey)
        guard fresh.operations.canWrite, fresh.operations.canDownload, !fresh.isGoogleDocument, let revision = fresh.headRevisionId,
            DriveLink.isValidID(revision)
        else { throw DriveError.permissionDenied }
        try RemoteFS.checkName(fresh.name)
        let id = UUID()
        let folder = directory.appendingPathComponent(fresh.id).appendingPathComponent(revision).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(fresh.name)
        let offline = try await client.offlineCopies()
        let baseline = try await offline.fetch(
            client.contentSource.remoteItem(fresh), progress: { bytes, total in context.progress(bytes, total ?? bytes) })
        let verified = try await client.file(fresh.id)
        guard verified.headRevisionId == revision else { throw DriveMutationError.conflict }
        try cloudClone(baseline, to: url)
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let session = DriveEditSession(id: id, localURL: url, file: fresh, sentMD5: try DriveClient.md5(url))
        try persist(session)
        sessions[id] = session; openSessions.insert(id)
        return session
    }
    public func save(_ id: UUID) async throws -> DriveFile {
        guard let client else { throw DriveError.reconnect }
        guard var session = sessions[id], saving.insert(id).inserted else { throw DriveMutationError.conflict }
        defer { saving.remove(id) }
        guard !client.isOffline else {
            session.state = .unsent(DriveError.offline.localizedDescription); try update(session)
            throw DriveError.offline
        }
        session.state = .saving; try update(session)
        do {
            let fresh = try await client.file(session.file.id)
            guard let revision = session.file.headRevisionId, fresh.headRevisionId == revision else { throw DriveMutationError.conflict }
            let md5 = try DriveClient.md5(session.localURL)
            if md5 == session.sentMD5 { session.state = .saved; try update(session); return fresh }
            // Snapshot the save: later edits cannot change the bytes this operation is uploading.
            let upload = directory.appendingPathComponent(UUID().uuidString + ".upload")
            try FileManager.default.copyItem(at: session.localURL, to: upload)
            defer { try? FileManager.default.removeItem(at: upload) }
            guard try DriveClient.md5(upload) == md5 else { throw DriveMutationError.sourceChanged }
            let result = try await client.saveEdit(upload, baseline: session.file)
            if let offline = try? await client.offlineCopies() {
                _ = try? await offline.adopt(file: upload, as: client.contentSource.remoteItem(result))
            }
            session.file = result; session.sentMD5 = md5; session.state = .saved; session.conflictURL = nil
            try update(session)
            return result
        } catch {
            if (error as? DriveMutationError) == .conflict {
                session.state = .conflict
                if let remote = try? await client.file(session.file.id), let bytes = try? await client.download(remote).data,
                    (try? RemoteFS.checkName(remote.name)) != nil
                {
                    let copy = session.localURL.deletingLastPathComponent().appendingPathComponent("Remote-" + remote.name)
                    try? bytes.write(to: copy, options: .atomic)
                    session.conflictURL = copy
                }
            } else {
                session.state = .unsent(error.localizedDescription)
            }
            try update(session)
            throw error
        }
    }
    public func keepBoth(_ id: UUID) async throws -> DriveFile {
        guard let client else { throw DriveError.reconnect }
        guard var session = sessions[id], saving.insert(id).inserted else { throw DriveMutationError.conflict }
        defer { saving.remove(id) }
        let current = try await client.file(session.file.id)
        let source = session.localURL
        let md5 = try DriveClient.md5(source)
        let result = try await client.upload(
            source, parentID: current.parents?.first ?? "root", name: FileFormat.noted(current.name, "edited on Mac"))
        session.file = result; session.sentMD5 = md5; session.state = .saved; session.conflictURL = nil
        try update(session)
        return result
    }
    public func replaceWithMine(_ id: UUID) async throws -> DriveFile {
        guard let client else { throw DriveError.reconnect }
        guard var session = sessions[id], !saving.contains(id) else { throw DriveMutationError.conflict }
        let current = try await client.file(session.file.id)
        guard let revision = current.headRevisionId, DriveLink.isValidID(revision) else { throw DriveMutationError.conflict }
        let url = client.baseURL.appendingPathComponent("files/\(current.id)/revisions/\(revision)")
        let (data, _) = try await client.mutationResponse(
            url, method: "PATCH", body: Data("{\"keepForever\":true}".utf8), headers: ["Content-Type": "application/json"])
        struct Revision: Decodable { let keepForever: Bool }
        guard try client.decode(Revision.self, data).keepForever else { throw DriveMutationError.conflict }
        session.file = current
        try update(session)
        return try await save(id)
    }
    private func update(_ session: DriveEditSession) throws {
        try persist(session)
        sessions[session.id] = session
        NotificationCenter.default.post(name: Self.changed, object: session.id)
    }
    private func persist(_ session: DriveEditSession) throws {
        let url = directory.appendingPathComponent(session.id.uuidString + ".json")
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
    }
}

extension DriveClient {
    /// One conditional publication; no gap between revision validation and server-side replacement.
    func saveEdit(_ local: URL, baseline: DriveFile) async throws -> DriveFile {
        // Live v3 conditional semantics must be established with a disposable account before enabling publication.
        guard canSaveEdits else { throw DriveError.safeUpdateUnavailable }
        try await tokens.requireWriteScope()
        var url = URLComponents(url: baseURL.appendingPathComponent("files/\(baseline.id)"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        let (data, response) = try await mutationResponse(url.url!)
        let fresh = try decode(DriveFile.self, data)
        guard let revision = baseline.headRevisionId, fresh.headRevisionId == revision,
            let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty,
            fresh.operations.canWrite, !fresh.isGoogleDocument
        else { throw DriveMutationError.conflict }
        var upload = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        upload.path = "/upload/" + upload.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/files/" + baseline.id
        upload.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: Self.fields),
        ]
        do {
            let (result, _) = try await mutationResponse(
                upload.url!, method: "PATCH", body: Data(contentsOf: local),
                headers: ["Content-Type": fresh.mimeType, "If-Match": etag])
            let file = try decode(DriveFile.self, result)
            guard file.id == baseline.id, file.md5Checksum == (try Self.md5(local)) else { throw DriveError.invalidResponse }
            remember([file]); invalidateMutation(parents: file.parents ?? [])
            return file
        } catch DriveError.http(412) { throw DriveMutationError.conflict }
    }
}
