import Foundation

/// Editable bytes are durable and held separately from the disposable rendition LRU.
public actor DropboxEditStore {
    public struct Session: Codable, Sendable {
        public var id: UUID
        public var file: DropboxItem
        public var localURL: URL
        public var sentHash: String
        public var state = "editing"
        public var uploadOperation: UUID?
    }
    private weak var client: DropboxClient?
    private let directory: URL
    private var sessions: [UUID: Session] = [:]
    private var open: Set<UUID> = []
    private var saving: Set<UUID> = []
    public init(client: DropboxClient) {
        self.client = client; directory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            if let bytes = try? Data(contentsOf: url), var session = try? JSONDecoder().decode(Session.self, from: bytes),
                session.localURL.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
            {
                if (try? DropboxContentHash.hash(session.localURL)) != session.sentHash { session.state = "unsent" }
                sessions[session.id] = session
            }
        }
    }
    public func session(_ id: UUID) -> Session? { sessions[id] }
    public func pending() -> [Session] { sessions.values.filter { (try? DropboxContentHash.hash($0.localURL)) != $0.sentHash } }
    public func holdsCopy(_ id: String) -> Bool {
        sessions.values.contains { $0.file.id == id && (open.contains($0.id) || (try? DropboxContentHash.hash($0.localURL)) != $0.sentHash) }
    }
    public func release(_ id: UUID) { open.remove(id) }
    public func begin(_ item: DropboxItem, context: CloudTransferContext = .init()) async throws -> Session {
        guard let client, item.rev != nil, item.pathDisplay != nil else { throw DropboxError.invalidLocation }
        if let existing = sessions.values.first(where: { $0.file.id == item.id && ($0.file.rev == item.rev || $0.state != "saved") }) {
            open.insert(existing.id); return existing
        }
        let staging = try await client.download(item, context: context)
        let id = UUID(); let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A fixed private basename avoids trusting server filenames as local paths.
        let local = folder.appendingPathComponent("content").appendingPathExtension((item.name as NSString).pathExtension)
        try cloudClone(staging, to: local)
        let session = Session(id: id, file: item, localURL: local, sentHash: try DropboxContentHash.hash(local))
        try persist(session); open.insert(id); return session
    }
    public func save(_ id: UUID, context: CloudTransferContext = .init()) async throws -> Session {
        guard let client, var session = sessions[id], let path = session.file.pathDisplay, let rev = session.file.rev else {
            throw DropboxError.invalidLocation
        }
        guard saving.insert(id).inserted else { throw CloudJournalError.busy }; defer { saving.remove(id) }
        let hash = try DropboxContentHash.hash(session.localURL)
        if hash == session.sentHash { return session }
        session.uploadOperation = session.uploadOperation ?? UUID(); session.state = "saving"; try persist(session)
        do {
            let result = try await client.upload(
                session.localURL, to: path, expectedRevision: rev, operationID: session.uploadOperation!, context: context)
            session.file = result; session.sentHash = result.contentHash ?? hash
            session.state = (try? DropboxContentHash.hash(session.localURL)) == session.sentHash ? "saved" : "unsent"
            session.uploadOperation = nil
            try persist(session); return session
        } catch {
            session.state = (error as? DropboxError) == .conflict ? "conflict" : "unsent"; try persist(session); throw error
        }
    }
    /// Conflict resolution writes a new name with add/autorename=false and preserves the original cloud item.
    public func saveAsCopy(_ id: UUID, to path: String, context: CloudTransferContext = .init()) async throws -> Session {
        guard let client, var session = sessions[id] else { throw DropboxError.invalidLocation }
        guard saving.insert(id).inserted else { throw CloudJournalError.busy }; defer { saving.remove(id) }
        let result = try await client.upload(session.localURL, to: path, context: context)
        session.file = result; session.sentHash = try result.contentHash ?? DropboxContentHash.hash(session.localURL)
        session.state = "saved"; session.uploadOperation = nil; try persist(session); return session
    }
    private func persist(_ session: Session) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(session.id.uuidString + ".json")
        try JSONEncoder().encode(session).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let handle = try FileHandle(forWritingTo: path); try handle.synchronize(); try handle.close(); sessions[session.id] = session
    }
}
