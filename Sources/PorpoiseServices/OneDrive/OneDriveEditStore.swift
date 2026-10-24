import Foundation
import PorpoiseCore

public typealias OneDriveEditStore = CloudEditSessionStore<OneDriveEditEngine>

/// Save-back is conditional on the revision the copy was made from (If-Match); Save as Copy names a new item beside it.
public struct OneDriveEditEngine: CloudEditEngine, @unchecked Sendable {
    private weak var client: OneDriveClient?
    public let directory: URL
    init(client: OneDriveClient) {
        self.client = client; directory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
    }
    public var unavailable: Error { OneDriveError.invalidLocation }
    public var sourceChanged: Error { OneDriveError.sourceChanged }
    private func connected() throws -> OneDriveClient { guard let client else { throw unavailable }; return client }
    public func checkConnection() throws { if try connected().isOffline { throw OneDriveError.offline } }
    public func canUseCached(after error: Error) -> Bool { (error as? OneDriveError) == .offline }
    public func identity(_ file: OneDriveItem) -> String { file.id }
    public func revision(_ file: OneDriveItem) -> String? { file.revision }
    public func hash(_ url: URL) throws -> String { try OneDriveContentHash.hash(url) }
    public func uploadSource(_ operation: UUID) -> URL? {
        guard let record = try? client?.journal.load(operation), let url = record.localURL,
            url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
        else { return nil }
        return url
    }
    public func prepare(_ file: OneDriveItem, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (OneDriveItem, URL) {
        let client = try connected()
        let file = try await client.metadata(file.id)
        guard file.revision != nil, file.parentID != nil, file.canDownload else { throw unavailable }
        return try await CloudStagedDownload.consume(
            journal: client.journal,
            download: {
                try await client.download(file, operationID: $0, context: context)
            }
        ) { staging in
            let folder = directory.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let local = folder.appendingPathComponent(try RemoteFS.localName(file.name))
            try cloudClone(staging, to: local); return (file, local)
        }
    }
    public func validate(_ file: OneDriveItem) async throws {
        _ = try connected()
        guard file.parentID != nil, file.revision != nil else { throw unavailable }
    }
    /// `copyPath` is the copy's name, in the file's own folder.
    public func publish(_ local: URL, file: OneDriveItem, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws
        -> OneDriveItem
    {
        let client = try connected()
        guard let parent = file.parentID, file.revision != nil else { throw unavailable }
        if let copyPath { return try await client.upload(local, to: parent, named: copyPath, operationID: operation, context: context) }
        return try await client.upload(local, to: parent, named: file.name, replacing: file, operationID: operation, context: context)
    }
    public func prepareReplacement(_ file: OneDriveItem) async throws -> OneDriveItem { try await connected().metadata(file.id) }
    public func conflict(_ error: Error) -> Bool { (error as? OneDriveError) == .conflict }
    public func remoteCopy(_ file: OneDriveItem, beside: URL) async -> URL? { nil }
}
extension CloudEditSessionStore where Engine == OneDriveEditEngine {
    public init(client: OneDriveClient) { self.init(engine: OneDriveEditEngine(client: client)) }
    public func begin(_ file: OneDriveItem, context: CloudTransferContext = .init()) async throws -> Session {
        if let existing = cachedSession(file) { retainCopy(existing.id); return existing }
        return try await openSession(file, context: context)
    }
    public func save(_ id: UUID, context: CloudTransferContext = .init()) async throws -> Session { try await saveSession(id, context: context) }
    public func saveAsCopy(_ id: UUID, named name: String, context: CloudTransferContext = .init()) async throws -> Session {
        try await saveSession(id, copyPath: name, context: context)
    }
    public func replace(_ id: UUID, expectedCurrent: OneDriveItem) async throws -> Session { try await replaceSession(id, current: expectedCurrent) }
}
