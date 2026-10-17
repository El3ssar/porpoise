import Foundation
import PorpoiseCore

/// Publication through an opaque-ID cloud API. A destination URL is returned only after verified publication.
public protocol CloudTransferProvider: CloudFileProvider {
    func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> FileItem
    func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> FileItem
    func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> FileItem?
    func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL
    func transferRevision(_ source: URL) -> String?
    func removeTransferredSource(_ source: URL, revision: String?) throws
}
extension DropboxProvider: CloudTransferProvider {
    public func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> FileItem {
        let client = try scoped(folder)
        return try CloudAwait.run {
            let parent = try await self.path(folder);
            return self.item(try await client.createFolder(name: name, parent: parent, operationID: operationID), client: client)
        }
    }
    public func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> FileItem
    {
        let client = try scoped(folder); let context = transferContext()
        return try CloudAwait.run {
            let path = try await DropboxClient.childPath(name: name, parent: self.path(folder))
            let revision: String?
            if replacing != nil {
                guard let expectedRevision else { throw DropboxError.sourceChanged }; revision = expectedRevision
            } else {
                revision = nil
            }
            return self.item(
                try await client.upload(local, to: path, expectedRevision: revision, operationID: operationID, context: context), client: client)
        }
    }
    public func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> FileItem? {
        guard let sourceLocation = DropboxLocation(url: source), sourceLocation.accountID == client.accountID,
            try scoped(source) === scoped(folder)
        else { return nil }
        let client = try scoped(folder)
        return try CloudAwait.run {
            let path = try await DropboxClient.childPath(name: name, parent: self.path(folder))
            let file = try await client.metadata(sourceLocation.itemID)
            let result: DropboxItem
            if move {
                result = try await client.move(file, to: path, operationID: operationID)
            } else {
                result = try await client.copy(file, to: path, operationID: operationID)
            }
            return self.item(result, client: client)
        }
    }
    public func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL {
        let client = try scoped(source); let id = try location(source).itemID; let context = transferContext()
        let file = try CloudAwait.run { try await client.metadata(id) }
        guard !file.isFolder else { return try download(source, into: folder) }
        let name = try RemoteFS.localName(file.name)
        let staged = try CloudAwait.run { try await client.download(file, operationID: operationID, context: context) }
        return try RemoteFS.downloadStaged(name, into: folder) { destination in
            try FileManager.default.copyItem(at: staged, to: destination.appendingPathComponent(name))
        }
    }
    public func transferRevision(_ source: URL) -> String? { metadata(source)?.rev }
    public func removeTransferredSource(_ source: URL, revision: String?) throws {
        let client = try scoped(source); let id = try location(source).itemID
        try CloudAwait.run {
            let file = try await client.metadata(id)
            guard !file.isFolder, file.rev == revision else { throw DropboxError.sourceChanged }
            _ = try await client.delete(file)
        }
    }
}
