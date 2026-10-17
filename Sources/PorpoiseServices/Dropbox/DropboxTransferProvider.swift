import Foundation
import PorpoiseCore

extension DropboxProvider: CloudTransferProvider {
    public func transferAccount(_ url: URL) throws -> String { try scoped(url).contentSource.accountID }
    public var supportsNativeTransferFolders: Bool { true }
    public func smallTransferItem(_ source: URL) -> FileItem? { nil }
    public func transferJournal(_ url: URL) throws -> CloudTransferJournal {
        CloudTransferJournal.at(try scoped(url).journal.folder.appendingPathComponent("Transfers"))
    }
    public var recoveryTransferJournals: [CloudTransferJournal] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: client.directory, includingPropertiesForKeys: nil)) ?? []
        return folders.map { CloudTransferJournal.at($0.appendingPathComponent("Operations/Transfers")) }
    }
    public func transferSnapshot(_ url: URL) throws -> CloudTransferSnapshot {
        let client = try scoped(url), id = try location(url).itemID
        let file = try client.metadataCache.file(id) ?? CloudAwait.run { try await client.metadata(id) }
        return CloudTransferSnapshot(item: client.contentSource.remoteItem(file))
    }
    public func transferRepresentation(_ source: URL, destinationAccount: String?) throws -> CloudTransferRepresentation {
        guard let file = metadata(source) else { throw DropboxError.notFound }
        return CloudTransferRepresentation(name: file.name)
    }
    private func transferReceipt(_ file: DropboxItem, client: DropboxClient) throws -> CloudTransferReceipt {
        let receipt = CloudTransferReceipt(
            url: DropboxLocation(accountID: client.accountID, itemID: file.id, namespaceID: client.namespaceID).url,
            snapshot: CloudTransferSnapshot(item: client.contentSource.remoteItem(file)))
        try verifyTransfer(receipt); return receipt
    }
    public func verifyTransfer(_ receipt: CloudTransferReceipt) throws {
        let client = try scoped(receipt.url), id = try location(receipt.url).itemID
        let fresh = try CloudAwait.run { try await client.metadata(id) }
        guard let expected = receipt.snapshot, expected.matches(CloudTransferSnapshot(item: client.contentSource.remoteItem(fresh))) else {
            throw DropboxError.sourceChanged
        }
    }
    public func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> CloudTransferReceipt {
        let client = try scoped(folder)
        let file = try CloudAwait.run { try await client.createFolder(name: name, parent: self.path(folder), operationID: operationID) }
        return try transferReceipt(file, client: client)
    }
    public func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> CloudTransferReceipt
    {
        let client = try scoped(folder), context = transferContext()
        let file = try CloudAwait.run {
            let path = try await DropboxClient.childPath(name: name, parent: self.path(folder))
            if replacing != nil, expectedRevision == nil { throw DropboxError.sourceChanged }
            return try await client.upload(
                local, to: path, expectedRevision: replacing == nil ? nil : expectedRevision, operationID: operationID, context: context)
        }
        return try transferReceipt(file, client: client)
    }
    public func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> CloudTransferReceipt? {
        guard let sourceLocation = DropboxLocation(url: source), sourceLocation.accountID == client.accountID, try scoped(source) === scoped(folder)
        else { return nil }
        let client = try scoped(folder)
        let result = try CloudAwait.run {
            let path = try await DropboxClient.childPath(name: name, parent: self.path(folder)),
                file = try await client.metadata(sourceLocation.itemID)
            if move { return try await client.move(file, to: path, operationID: operationID) }
            return try await client.copy(file, to: path, operationID: operationID)
        }
        var receipt = try transferReceipt(result, client: client); receipt.sourceRemoved = move; return receipt
    }
    public func recoverTransfer(_ operation: UUID, in folder: URL) throws -> CloudTransferReceipt? {
        let client = try scoped(folder)
        guard let record = try client.journal.load(operation) else { return nil }
        if record.phase == "done", let result = record.result {
            var receipt = try transferReceipt(result, client: client); receipt.sourceRemoved = record.kind == "files/move_v2"; return receipt
        }
        if ["uncertain", "submitted", "committing"].contains(record.phase) { throw DropboxError.uncertain }
        return nil
    }
    public func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL {
        let client = try scoped(source), id = try location(source).itemID, context = transferContext()
        let file = try CloudAwait.run { try await client.metadata(id) }
        guard !file.isFolder else { return try download(source, into: folder) }
        let name = try RemoteFS.localName(file.name)
        let staged = try CloudAwait.run { try await client.download(file, operationID: operationID, context: context) }
        return try RemoteFS.downloadStaged(name, into: folder) { destination in
            try FileManager.default.copyItem(at: staged, to: destination.appendingPathComponent(name))
        }
    }
    public func removeTransferredSource(_ source: URL, snapshot: CloudTransferSnapshot?, revision: String?) throws {
        let client = try scoped(source), id = try location(source).itemID
        try CloudAwait.run {
            let file = try await client.metadata(id), current = CloudTransferSnapshot(item: client.contentSource.remoteItem(file))
            guard !file.isFolder, snapshot.map({ $0.matches(current) }) ?? (revision == file.rev) else { throw DropboxError.sourceChanged }
            _ = try await client.delete(file)
        }
    }
    public func cancelTransferredOperation(_ operation: UUID, at url: URL) throws {
        let client = try scoped(url)
        try client.journal.claim(operation); defer { client.journal.release(operation) }
        guard var record = try client.journal.load(operation) else { return }
        if record.kind == "download" {
            let partial = client.journal.partial(operation)
            guard record.localURL == nil || record.localURL == partial else { throw DropboxError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(partial, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw DropboxError.sourceChanged
            }
            record.phase = "prepared"; record.localURL = nil; record.fingerprint = nil; record.downloadRanges = nil; record.offset = 0
            try client.journal.save(record)
        } else if record.kind == "upload", !["done", "uncertain", "committing"].contains(record.phase) {
            try CloudAwait.run { try await client.tokens.removeSecret(operation) }
            record.hasSession = false; record.offset = 0; record.proposedOffset = nil; record.phase = "prepared"; try client.journal.save(record)
        }
    }
}
