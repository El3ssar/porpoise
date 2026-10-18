import Foundation
import PorpoiseCore

extension OneDriveProvider: CloudTransferProvider {
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
        guard let file = metadata(source) else { throw OneDriveError.notFound }
        return CloudTransferRepresentation(name: file.name)
    }
    private func transferReceipt(_ file: OneDriveItem, client: OneDriveClient) throws -> CloudTransferReceipt {
        let receipt = CloudTransferReceipt(
            url: OneDriveLocation(accountID: client.accountID, itemID: file.id, driveID: client.driveID).url,
            snapshot: CloudTransferSnapshot(item: client.contentSource.remoteItem(file)))
        try verifyTransfer(receipt); return receipt
    }
    public func verifyTransfer(_ receipt: CloudTransferReceipt) throws {
        let client = try scoped(receipt.url), id = try location(receipt.url).itemID
        let fresh = try CloudAwait.run { try await client.metadata(id) }
        guard let expected = receipt.snapshot, expected.matches(CloudTransferSnapshot(item: client.contentSource.remoteItem(fresh))) else {
            throw OneDriveError.sourceChanged
        }
    }
    public func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> CloudTransferReceipt {
        let client = try scoped(folder), parent = try folderID(folder)
        let file = try CloudAwait.run { try await client.createFolder(name: name, parentID: parent, operationID: operationID) }
        return try transferReceipt(file, client: client)
    }
    public func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> CloudTransferReceipt
    {
        let client = try scoped(folder), parent = try folderID(folder), context = transferContext()
        let file = try CloudAwait.run {
            guard let replacing else { return try await client.upload(local, to: parent, named: name, operationID: operationID, context: context) }
            guard let expectedRevision, try self.scoped(replacing) === client else { throw OneDriveError.sourceChanged }
            let current = try await client.metadata(self.location(replacing).itemID)
            guard current.name == name else { throw OneDriveError.sourceChanged }
            // Changed since the conflict was chosen: the destination isn't the one agreed to replace.
            guard current.revision == expectedRevision else { throw OneDriveError.conflict }
            return try await client.upload(local, to: parent, named: name, replacing: current, operationID: operationID, context: context)
        }
        return try transferReceipt(file, client: client)
    }
    public func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> CloudTransferReceipt? {
        guard let sourceLocation = OneDriveLocation(url: source), sourceLocation.accountID == client.accountID, try scoped(source) === scoped(folder)
        else { return nil }
        let client = try scoped(folder), parent = try folderID(folder)
        let result = try CloudAwait.run {
            let file = try await client.metadata(sourceLocation.itemID)
            if parent.isEmpty, client.rootID == nil { _ = try await client.metadata("") }
            if move { return try await client.move(file, to: parent, named: name, operationID: operationID) }
            return try await client.copy(file, to: parent, named: name, operationID: operationID)
        }
        var receipt = try transferReceipt(result, client: client); receipt.sourceRemoved = move; return receipt
    }
    public func recoverTransfer(_ operation: UUID, in folder: URL) throws -> CloudTransferReceipt? {
        let client = try scoped(folder)
        guard let record = try client.journal.load(operation) else { return nil }
        if record.phase == "done", let result = record.result {
            var receipt = try transferReceipt(result, client: client); receipt.sourceRemoved = record.kind == "move"; return receipt
        }
        if ["uncertain", "submitted", "committing"].contains(record.phase) { throw OneDriveError.uncertain }
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
            guard !file.isFolder, snapshot.map({ $0.matches(current) }) ?? (revision == file.revision) else { throw OneDriveError.sourceChanged }
            _ = try await client.delete(file)
        }
    }
    public func cancelTransferredOperation(_ operation: UUID, at url: URL) throws {
        let client = try scoped(url)
        try client.journal.claim(operation); defer { client.journal.release(operation) }
        guard var record = try client.journal.load(operation) else { return }
        if record.kind == "download" {
            let partial = client.journal.partial(operation)
            guard record.localURL == nil || record.localURL == partial else { throw OneDriveError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(partial, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw OneDriveError.sourceChanged
            }
            record.phase = "prepared"; record.localURL = nil; record.fingerprint = nil; record.downloadRanges = nil; record.offset = 0
            try client.journal.save(record)
        } else if ["upload", "replace"].contains(record.kind), !["done", "uncertain", "committing"].contains(record.phase) {
            try CloudAwait.run { try await client.tokens.removeSecret(operation) }
            record.hasSession = false; record.offset = 0; record.proposedOffset = nil; record.phase = "prepared"; try client.journal.save(record)
        }
    }
}
