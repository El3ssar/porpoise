import Foundation
import PorpoiseCore

extension BoxProvider: CloudTransferProvider {
    public func transferAccount(_ url: URL) throws -> String { _ = try location(url); return client.contentSource.accountID }
    public var supportsNativeTransferFolders: Bool { true }
    public func smallTransferItem(_ source: URL) -> FileItem? { nil }
    public func transferJournal(_ url: URL) throws -> CloudTransferJournal {
        _ = try location(url); return CloudTransferJournal.at(client.journal.folder.appendingPathComponent("Transfers"))
    }
    public var recoveryTransferJournals: [CloudTransferJournal] {
        [CloudTransferJournal.at(client.journal.folder.appendingPathComponent("Transfers"))]
    }
    public func transferSnapshot(_ url: URL) throws -> CloudTransferSnapshot {
        let file = try metadata(url) ?? CloudAwait.run { try await self.fetch(url) }
        return CloudTransferSnapshot(item: client.contentSource.remoteItem(file))
    }
    public func transferRepresentation(_ source: URL, destinationAccount: String?) throws -> CloudTransferRepresentation {
        guard let file = metadata(source) else { throw BoxError.notFound }
        return CloudTransferRepresentation(name: file.name)
    }
    private func transferReceipt(_ file: BoxItem) throws -> CloudTransferReceipt {
        let receipt = CloudTransferReceipt(url: item(file).url, snapshot: CloudTransferSnapshot(item: client.contentSource.remoteItem(file)))
        try verifyTransfer(receipt); return receipt
    }
    public func verifyTransfer(_ receipt: CloudTransferReceipt) throws {
        let fresh = try CloudAwait.run { try await self.fetch(receipt.url) }
        guard let expected = receipt.snapshot, expected.matches(CloudTransferSnapshot(item: client.contentSource.remoteItem(fresh))) else {
            throw BoxError.sourceChanged
        }
    }
    public func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> CloudTransferReceipt {
        let parent = try folderID(folder)
        let file = try CloudAwait.run { try await self.client.createFolder(name: name, parentID: parent, operationID: operationID) }
        return try transferReceipt(file)
    }
    public func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> CloudTransferReceipt
    {
        let parent = try folderID(folder), context = transferContext(), client = client
        let file = try CloudAwait.run {
            guard let replacing else { return try await client.upload(local, to: parent, named: name, operationID: operationID, context: context) }
            guard let expectedRevision else { throw BoxError.sourceChanged }
            let current = try await self.fetch(replacing)
            guard current.name == name, current.kind == .file else { throw BoxError.sourceChanged }
            // Changed since the conflict was chosen: the destination isn't the one agreed to replace.
            guard current.revision == expectedRevision else { throw BoxError.conflict }
            return try await client.upload(local, to: parent, named: name, replacing: current, operationID: operationID, context: context)
        }
        return try transferReceipt(file)
    }
    public func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> CloudTransferReceipt? {
        guard let sourceLocation = BoxLocation(url: source), sourceLocation.accountID == client.accountID else { return nil }
        let parent = try folderID(folder), client = client
        let result = try CloudAwait.run {
            let file = try await self.fetch(source)
            if move { return try await client.move(file, to: parent, named: name, operationID: operationID) }
            return try await client.copy(file, to: parent, named: name, operationID: operationID)
        }
        var receipt = try transferReceipt(result); receipt.sourceRemoved = move; return receipt
    }
    public func recoverTransfer(_ operation: UUID, in folder: URL) throws -> CloudTransferReceipt? {
        _ = try location(folder)
        guard let record = try client.journal.load(operation) else { return nil }
        if record.phase == "done", let result = record.result {
            var receipt = try transferReceipt(result); receipt.sourceRemoved = record.kind == "move"; return receipt
        }
        if ["uncertain", "submitted", "committing"].contains(record.phase) { throw BoxError.uncertain }
        return nil
    }
    public func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL {
        let context = transferContext(), client = client
        let file = try CloudAwait.run { try await self.fetch(source) }
        guard !file.isFolder else { return try download(source, into: folder) }
        let name = try RemoteFS.localName(file.name)
        let staged = try CloudAwait.run { try await client.download(file, operationID: operationID, context: context) }
        return try RemoteFS.downloadStaged(name, into: folder) { destination in
            try FileManager.default.copyItem(at: staged, to: destination.appendingPathComponent(name))
        }
    }
    public func removeTransferredSource(_ source: URL, snapshot: CloudTransferSnapshot?, revision: String?) throws {
        let client = client
        try CloudAwait.run {
            let file = try await self.fetch(source), current = CloudTransferSnapshot(item: client.contentSource.remoteItem(file))
            guard !file.isFolder, snapshot.map({ $0.matches(current) }) ?? (revision == file.revision) else { throw BoxError.sourceChanged }
            _ = try await client.delete(file)
        }
    }
    public func cancelTransferredOperation(_ operation: UUID, at url: URL) throws {
        _ = try location(url)
        try client.journal.claim(operation); defer { client.journal.release(operation) }
        guard var record = try client.journal.load(operation) else { return }
        if record.kind == "download" {
            let partial = client.journal.partial(operation)
            guard record.localURL == nil || record.localURL == partial else { throw BoxError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(partial, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw BoxError.sourceChanged
            }
            record.phase = "prepared"; record.localURL = nil; record.fingerprint = nil; record.downloadRanges = nil; record.offset = 0
            try client.journal.save(record)
        } else if ["upload", "replace"].contains(record.kind), !["done", "uncertain", "committing"].contains(record.phase) {
            let client = client
            try CloudAwait.run { try await client.tokens.removeSecret(operation) }
            record.hasSession = false; record.offset = 0; record.proposedOffset = nil; record.parts = nil; record.phase = "prepared"
            try client.journal.save(record)
        }
    }
}
