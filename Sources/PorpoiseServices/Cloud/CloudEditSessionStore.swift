import Foundation

public enum CloudEditState: Codable, Sendable, Equatable {
    case editing, saving, saved, conflict, unsent(String)
}

/// The common durable record. The decoder also reads both providers' pre-consolidation records.
public struct CloudEditSession<File: Codable & Sendable>: Codable, Sendable, Identifiable {
    public let id: UUID
    public let localURL: URL
    public var file: File
    public var state: CloudEditState = .editing
    public var conflictURL: URL?
    public var sentHash: String
    public var uploadOperation: UUID?
    var sentMD5: String {
        get { sentHash }
        set { sentHash = newValue }
    }
    public init(id: UUID, localURL: URL, file: File, sentHash: String) {
        self.id = id; self.localURL = localURL; self.file = file; self.sentHash = sentHash
    }
    private enum CodingKeys: String, CodingKey { case id, localURL, file, state, conflictURL, sentHash, sentMD5, uploadOperation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); localURL = try c.decode(URL.self, forKey: .localURL)
        file = try c.decode(File.self, forKey: .file)
        sentHash = try c.decodeIfPresent(String.self, forKey: .sentHash) ?? c.decode(String.self, forKey: .sentMD5)
        conflictURL = try c.decodeIfPresent(URL.self, forKey: .conflictURL)
        uploadOperation = try c.decodeIfPresent(UUID.self, forKey: .uploadOperation)
        if let legacy = try? c.decode(String.self, forKey: .state) {
            switch legacy {
            case "editing": state = .editing
            case "saving": state = .saving
            case "saved": state = .saved
            case "conflict": state = .conflict
            default: state = .unsent("Saved changes have not reached the cloud.")
            }
        } else {
            state = try c.decode(CloudEditState.self, forKey: .state)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(localURL, forKey: .localURL); try c.encode(file, forKey: .file)
        try c.encode(state, forKey: .state); try c.encode(sentHash, forKey: .sentHash)
        try c.encodeIfPresent(conflictURL, forKey: .conflictURL); try c.encodeIfPresent(uploadOperation, forKey: .uploadOperation)
    }
}

/// Only provider I/O and revision policy vary. The store owns recovery, retention, snapshots and publication state.
public protocol CloudEditEngine: Sendable {
    associatedtype File: Codable & Sendable
    var directory: URL { get }
    var unavailable: Error { get }
    var sourceChanged: Error { get }
    func checkConnection() throws
    func canUseCached(after error: Error) -> Bool
    func identity(_ file: File) -> String
    func revision(_ file: File) -> String?
    func hash(_ url: URL) throws -> String
    func uploadSource(_ operation: UUID) -> URL?
    func prepare(_ file: File, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (File, URL)
    func validate(_ file: File) async throws
    func publish(_ local: URL, file: File, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws -> File
    func prepareReplacement(_ file: File) async throws -> File
    func conflict(_ error: Error) -> Bool
    func remoteCopy(_ file: File, beside: URL) async -> URL?
}

/// Editable bytes never enter a disposable rendition cache. A hash comparison discovers saves after a crash.
public actor CloudEditSessionStore<Engine: CloudEditEngine> {
    public typealias Session = CloudEditSession<Engine.File>
    public static var changed: Notification.Name { Notification.Name("PorpoiseCloudEditSessionChanged") }
    let engine: Engine
    private var sessions: [UUID: Session] = [:]
    private var saving: Set<UUID> = []
    private var openSessions: Set<UUID> = []
    /// Opens in flight by file identity: an overlapping open of the same file shares the one copy.
    private var opening: [String: Task<Session, Error>] = [:]
    private let metadataOwnership: (@Sendable ([Engine.File], Bool) -> Void)?
    private var metadataOwnershipComplete = true
    public init(engine: Engine) {
        self.init(engine: engine, metadataOwnership: nil)
    }
    init(engine: Engine, metadataOwnership: (@Sendable ([Engine.File], Bool) -> Void)?) {
        self.engine = engine
        self.metadataOwnership = metadataOwnership
        let records: [URL]
        do { records = try FileManager.default.contentsOfDirectory(at: engine.directory, includingPropertiesForKeys: nil) } catch {
            records = []; metadataOwnershipComplete = CloudMetadataOwnership.missing(error)
        }
        for url in records
        where url.pathExtension == "json" {
            if let bytes = try? Data(contentsOf: url), var session = try? JSONDecoder().decode(Session.self, from: bytes),
                session.localURL.standardizedFileURL.path.hasPrefix(engine.directory.standardizedFileURL.path + "/")
            {
                if session.state != .conflict, (try? engine.hash(session.localURL)) != session.sentHash {
                    session.state = .unsent("Saved changes have not reached the cloud.")
                }
                sessions[session.id] = session
            } else {
                metadataOwnershipComplete = false
            }
        }
        metadataOwnership?(sessions.values.map(\.file), metadataOwnershipComplete)
    }
    public func session(_ id: UUID) -> Session? { sessions[id] }
    public func pending() -> [Session] {
        sessions.values.filter { dirty($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func dirty(_ session: Session) -> Bool { (try? engine.hash(session.localURL)) != session.sentHash }
    public func holdsCopy(_ id: String) -> Bool {
        sessions.values.contains { engine.identity($0.file) == id && (openSessions.contains($0.id) || dirty($0)) }
    }
    public func retainCopy(_ id: UUID) { openSessions.insert(id) }
    public func releaseCopy(_ id: UUID) { openSessions.remove(id) }
    public func release(_ id: UUID) { releaseCopy(id) }
    public func cachedSession(_ file: Engine.File) -> Session? {
        sessions.values.first {
            engine.identity($0.file) == engine.identity(file)
                && (engine.revision($0.file) == engine.revision(file) || dirty($0) || $0.state == .conflict)
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }
    }
    public func openSession(_ file: Engine.File, context: CloudTransferContext = .init()) async throws -> Session {
        do { try engine.checkConnection() } catch {
            if engine.canUseCached(after: error), let existing = cachedSession(file) {
                openSessions.insert(existing.id); return existing
            }
            throw error
        }
        if let existing = pending().first(where: { engine.identity($0.file) == engine.identity(file) }),
            FileManager.default.fileExists(atPath: existing.localURL.path)
        {
            openSessions.insert(existing.id); return existing
        }
        let key = engine.identity(file)
        while let shared = opening[key] {
            do {
                let session = try await shared.value
                openSessions.insert(session.id); return session
            } catch _ where !Task.isCancelled {
                // Its starter's failure may be its own (canceled, or stopped in Activity): this caller tries itself.
                if opening[key] == shared { opening[key] = nil }
            }
        }
        let task = Task { try await prepareSession(file, context: context) }
        opening[key] = task
        defer { if opening[key] == task { opening[key] = nil } }
        let session = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        openSessions.insert(session.id); return session
    }
    private func prepareSession(_ file: Engine.File, context: CloudTransferContext) async throws -> Session {
        let id = UUID()
        let (fresh, url) = try await engine.prepare(file, id: id, directory: engine.directory, context: context)
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let session = Session(id: id, localURL: url, file: fresh, sentHash: try engine.hash(url))
        try update(session); return session
    }
    public func saveSession(_ id: UUID, copyPath: String? = nil, context: CloudTransferContext = .init()) async throws -> Session {
        guard var session = sessions[id] else { throw engine.unavailable }
        guard saving.insert(id).inserted else { throw CloudJournalError.busy }
        defer { saving.remove(id) }
        do {
            try engine.checkConnection()
            if copyPath == nil { try await engine.validate(session.file) }
            let hash = try engine.hash(session.localURL)
            if hash == session.sentHash, copyPath == nil { session.state = .saved; try update(session); return session }
            session.uploadOperation = copyPath == nil ? session.uploadOperation ?? UUID() : UUID(); session.state = .saving; try update(session)
            // Retain the exact inode across failed uploads: resumable journals fingerprint their source.
            let upload =
                engine.uploadSource(session.uploadOperation!)
                ?? engine.directory.appendingPathComponent(session.uploadOperation!.uuidString + ".upload")
            if !FileManager.default.fileExists(atPath: upload.path) {
                try FileManager.default.copyItem(at: session.localURL, to: upload)
                guard try engine.hash(upload) == hash else {
                    try? FileManager.default.removeItem(at: upload)
                    throw engine.sourceChanged
                }
            }
            let uploadHash = try engine.hash(upload)
            session.file = try await engine.publish(
                upload, file: session.file, operation: session.uploadOperation!, copyPath: copyPath, context: context)
            session.sentHash = uploadHash; session.uploadOperation = nil; session.conflictURL = nil
            session.state = dirty(session) ? .unsent("New changes are waiting to send.") : .saved
            try update(session)
            if upload != session.localURL { try? FileManager.default.removeItem(at: upload) }
            return session
        } catch {
            if engine.conflict(error) {
                session.state = .conflict
                session.conflictURL = await engine.remoteCopy(session.file, beside: session.localURL)
            } else {
                session.state = .unsent(error.localizedDescription)
            }
            try update(session); throw error
        }
    }
    public func replaceSession(_ id: UUID, current: Engine.File? = nil) async throws -> Session {
        try engine.checkConnection()
        guard var session = sessions[id], !saving.contains(id) else { throw CloudJournalError.busy }
        if let current {
            guard engine.identity(current) == engine.identity(session.file), engine.revision(current) != nil else { throw engine.unavailable }
            session.file = current
        } else {
            session.file = try await engine.prepareReplacement(session.file)
        }
        session.uploadOperation = nil; try update(session)
        return try await saveSession(id)
    }
    private func update(_ session: Session) throws {
        // Protect new identity/ancestry before writing, and keep the old durable identity until commit.
        metadataOwnership?(sessions.values.map(\.file) + [session.file], metadataOwnershipComplete)
        do {
            try FileManager.default.createDirectory(at: engine.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = engine.directory.appendingPathComponent(session.id.uuidString + ".json")
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
            sessions[session.id] = session
        } catch {
            metadataOwnership?(sessions.values.map(\.file), metadataOwnershipComplete)
            throw error
        }
        metadataOwnership?(sessions.values.map(\.file), metadataOwnershipComplete)
        NotificationCenter.default.post(name: Self.changed, object: session.id)
    }
}
