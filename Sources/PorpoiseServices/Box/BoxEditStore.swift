import Foundation
import PorpoiseCore

public typealias BoxEditStore = CloudEditSessionStore<BoxEditEngine>

/// Save-back is conditional on the revision the copy was made from (If-Match); Save as Copy names a new item beside it.
public struct BoxEditEngine: CloudEditEngine, @unchecked Sendable {
    private weak var client: BoxClient?
    public let directory: URL
    init(client: BoxClient) {
        self.client = client; directory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
    }
    public var unavailable: Error { BoxError.invalidLocation }
    public var sourceChanged: Error { BoxError.sourceChanged }
    private func connected() throws -> BoxClient { guard let client else { throw unavailable }; return client }
    public func checkConnection() throws { if try connected().isOffline { throw BoxError.offline } }
    public func canUseCached(after error: Error) -> Bool { (error as? BoxError) == .offline }
    public func identity(_ file: BoxItem) -> String { file.id }
    public func revision(_ file: BoxItem) -> String? { file.revision }
    public func hash(_ url: URL) throws -> String { try BoxContentHash.hash(url) }
    public func uploadSource(_ operation: UUID) -> URL? {
        guard let record = try? client?.journal.load(operation), let url = record.localURL,
            url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
        else { return nil }
        return url
    }
    public func prepare(_ file: BoxItem, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (BoxItem, URL) {
        let client = try connected()
        let file = try await client.metadata(file.id, kind: .file)
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
    public func validate(_ file: BoxItem) async throws {
        _ = try connected()
        guard file.parentID != nil, file.revision != nil else { throw unavailable }
    }
    /// `copyPath` is the copy's name, in the file's own folder.
    public func publish(_ local: URL, file: BoxItem, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws
        -> BoxItem
    {
        let client = try connected()
        guard let parent = file.parentID, file.revision != nil else { throw unavailable }
        if let copyPath { return try await client.upload(local, to: parent, named: copyPath, operationID: operation, context: context) }
        return try await client.upload(local, to: parent, named: file.name, replacing: file, operationID: operation, context: context)
    }
    public func prepareReplacement(_ file: BoxItem) async throws -> BoxItem { try await connected().metadata(file.id, kind: .file) }
    public func conflict(_ error: Error) -> Bool { (error as? BoxError) == .conflict }
    public func remoteCopy(_ file: BoxItem, beside: URL) async -> URL? { nil }
}
extension CloudEditSessionStore where Engine == BoxEditEngine {
    public init(client: BoxClient) {
        let engine = BoxEditEngine(client: client), name = CloudMetadataOwnership.key("edits", directory: engine.directory)
        self.init(engine: engine) { [weak client] files, complete in
            client?.metadataCache.setRetentionOwner(name, .init(owner: .init(items: Set(files.map(\.id))), files: files, complete: complete))
        }
    }
    public func begin(_ file: BoxItem, context: CloudTransferContext = .init()) async throws -> Session {
        if let existing = cachedSession(file) { retainCopy(existing.id); return existing }
        return try await openSession(file, context: context)
    }
    public func save(_ id: UUID, context: CloudTransferContext = .init()) async throws -> Session { try await saveSession(id, context: context) }
    public func saveAsCopy(_ id: UUID, named name: String, context: CloudTransferContext = .init()) async throws -> Session {
        try await saveSession(id, copyPath: name, context: context)
    }
    public func replace(_ id: UUID, expectedCurrent: BoxItem) async throws -> Session { try await replaceSession(id, current: expectedCurrent) }
}
