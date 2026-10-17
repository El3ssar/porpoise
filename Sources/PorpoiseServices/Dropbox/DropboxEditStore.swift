import Foundation

public typealias DropboxEditStore = CloudEditSessionStore<DropboxEditEngine>

public struct DropboxEditEngine: CloudEditEngine, @unchecked Sendable {
    private weak var client: DropboxClient?
    public let directory: URL
    init(client: DropboxClient) {
        self.client = client; directory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
    }
    public var unavailable: Error { DropboxError.invalidLocation }
    public var sourceChanged: Error { DropboxError.sourceChanged }
    private func connected() throws -> DropboxClient { guard let client else { throw unavailable }; return client }
    public func checkConnection() throws { if try connected().isOffline { throw DropboxError.offline } }
    public func canUseCached(after error: Error) -> Bool { (error as? DropboxError) == .offline }
    public func identity(_ file: DropboxItem) -> String { file.id }
    public func revision(_ file: DropboxItem) -> String? { file.rev }
    public func hash(_ url: URL) throws -> String { try DropboxContentHash.hash(url) }
    public func uploadSource(_ operation: UUID) -> URL? {
        guard let record = try? client?.journal.load(operation), let url = record.localURL,
            url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
        else { return nil }
        return url
    }
    public func prepare(_ file: DropboxItem, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (DropboxItem, URL) {
        let client = try connected()
        let file = try await client.metadata(file.id)
        guard file.rev != nil, file.pathDisplay != nil else { throw unavailable }
        let staging = try await client.download(file, context: context)
        let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = folder.appendingPathComponent("content").appendingPathExtension((file.name as NSString).pathExtension)
        try cloudClone(staging, to: local); return (file, local)
    }
    public func validate(_ file: DropboxItem) async throws {
        _ = try connected()
        guard file.pathDisplay != nil, file.rev != nil else { throw unavailable }
    }
    public func publish(_ local: URL, file: DropboxItem, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws
        -> DropboxItem
    {
        let client = try connected()
        guard let path = copyPath ?? file.pathDisplay, let rev = file.rev else { throw unavailable }
        return try await client.upload(local, to: path, expectedRevision: copyPath == nil ? rev : nil, operationID: operation, context: context)
    }
    public func prepareReplacement(_ file: DropboxItem) async throws -> DropboxItem { try await connected().metadata(file.id) }
    public func conflict(_ error: Error) -> Bool { (error as? DropboxError) == .conflict }
    public func remoteCopy(_ file: DropboxItem, beside: URL) async -> URL? { nil }
}
extension CloudEditSessionStore where Engine == DropboxEditEngine {
    public init(client: DropboxClient) { self.init(engine: DropboxEditEngine(client: client)) }
    public func begin(_ file: DropboxItem, context: CloudTransferContext = .init()) async throws -> Session {
        if let existing = cachedSession(file) { retainCopy(existing.id); return existing }
        return try await openSession(file, context: context)
    }
    public func save(_ id: UUID, context: CloudTransferContext = .init()) async throws -> Session { try await saveSession(id, context: context) }
    public func saveAsCopy(_ id: UUID, to path: String, context: CloudTransferContext = .init()) async throws -> Session {
        try await saveSession(id, copyPath: path, context: context)
    }
    public func replace(_ id: UUID, expectedCurrent: DropboxItem) async throws -> Session { try await replaceSession(id, current: expectedCurrent) }
}
