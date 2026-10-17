import Foundation
import PorpoiseCore

extension DriveProvider: CloudTransferProvider {
    public func transferAccount(_ url: URL) throws -> String { try location(url).accountID.uuidString.lowercased() }
    public var supportsNativeTransferFolders: Bool { false }
    public func transferJournal(_ url: URL) throws -> CloudTransferJournal {
        guard let client else { throw DriveError.reconnect }
        return Self.transferJournal(client.mutationJournal)
    }
    static func transferJournal(_ journal: DriveMutationJournal) -> CloudTransferJournal {
        CloudTransferJournal.at(
            journal.folder.appendingPathComponent("Transfers"),
            legacy: { id in
                let records: [DriveMutationRecord]
                if let id { records = try journal.load(id).map { [$0] } ?? [] } else { records = try journal.all() }
                return records.compactMap { old in
                    guard old.kind == "transferMove" || old.kind == "transferCopy", let source = old.localSource, let folder = old.destinationFolder
                    else { return nil }
                    var record = CloudTransferRecord(
                        operationID: old.operationID, kind: old.kind == "transferMove" ? "move" : "copy", source: source, destinationFolder: folder)
                    record.batchID = old.batchID; record.topLevel = old.topLevel == true; record.sourceFingerprint = old.fingerprint
                    record.sourceRevision = old.revision; record.childOperationID = old.childOperationID;
                    record.downloadOperationID = old.downloadOperationID
                    record.targetURL = old.destinationURL; record.phase = CloudTransferRecord.Phase(rawValue: old.phase.rawValue) ?? .transferring
                    record.sourceAccount = DriveLocation(url: source).map { $0.accountID.uuidString.lowercased() }
                    record.destinationAccount = DriveLocation(url: folder).map { $0.accountID.uuidString.lowercased() }
                    if let url = old.destinationURL {
                        let account = DriveLocation(url: url)?.accountID ?? old.accountID
                        record.receipt = CloudTransferReceipt(
                            url: url, snapshot: old.result.map { driveTransferSnapshot($0, account: account) },
                            fingerprint: old.destinationFingerprint, digest: old.destinationDigest,
                            sourceRemoved: old.kind == "transferMove" && old.sourceID != nil && old.result?.id == old.sourceID)
                    }
                    return record
                }
            })
    }
    public var recoveryTransferJournals: [CloudTransferJournal] { client.map { [Self.transferJournal($0.mutationJournal)] } ?? [] }
    public func transferSnapshot(_ url: URL) throws -> CloudTransferSnapshot {
        guard let client else { throw DriveError.reconnect }
        let file: DriveFile
        if let small = smallTransferItem(url), let known = metadata(for: small.url) {
            file = known
        } else {
            guard case .folder(let id, _) = try location(url).collection else { throw DriveError.invalidLocation }
            file = try CloudAwait.run { try await client.file(id) }
        }
        return driveTransferSnapshot(file, account: accountID)
    }
    public func transferRepresentation(_ source: URL, destinationAccount: String?) throws -> CloudTransferRepresentation {
        guard let file = metadata(for: source) else { throw DriveError.notFound }
        if file.isGoogleDocument, destinationAccount != accountID.uuidString.lowercased() {
            let preset = DriveExportPreset(rawValue: Settings.store.string(forKey: CloudAccounts.exportPresetKey) ?? "") ?? .office
            guard let format = preset.format(for: file.mimeType) else { throw DriveError.unsupportedExport }
            return CloudTransferRepresentation(name: file.name + "." + format.fileExtension, allowsMove: false)
        }
        return CloudTransferRepresentation(name: file.name)
    }
    public func smallTransferItem(_ source: URL) -> FileItem? {
        guard let file = metadata(for: source), !file.isFolder, !file.isGoogleDocument, file.shortcutDetails == nil,
            file.version != nil, file.md5Checksum != nil, let size = file.size.flatMap(Int64.init), size >= 0, size < 8 << 20
        else { return nil }
        return file.fileItem(accountID: accountID)
    }
    public func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> CloudTransferReceipt {
        guard let client else { throw DriveError.reconnect }
        let parent = try parentID(folder)
        let file = try CloudAwait.run { try await client.createFolder(name: name, parentID: parent, operationID: operationID) }
        return try transferReceipt(file, in: folder)
    }
    public func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> CloudTransferReceipt
    {
        guard let client else { throw DriveError.reconnect }
        let parent = try parentID(folder), context = transferContext()
        let replacingID: String?
        if let replacing {
            guard let old = metadata(for: replacing), !old.isGoogleDocument, expectedRevision != nil else { throw DriveMutationError.conflict }
            replacingID = old.id
        } else {
            replacingID = nil
        }
        let file = try CloudAwait.run {
            try await client.upload(
                local, parentID: parent, name: name, operationID: operationID, context: context,
                replacingID: replacingID, expectedVersion: expectedRevision)
        }
        return try transferReceipt(file, in: folder)
    }
    public func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> CloudTransferReceipt? {
        guard let location = DriveLocation(url: source), location.accountID == accountID, case .folder(let id, _) = location.collection, let client
        else { return nil }
        let parent = try parentID(folder)
        let result = try CloudAwait.run {
            let file = try await client.file(id), destination = try await client.file(parent)
            if move, file.driveId == destination.driveId {
                return (try await client.move(file.id, to: parent, operationID: operationID, name: name), true)
            }
            if move, file.capabilities?.canMoveItemOutOfDrive != true { throw DriveError.permissionDenied }
            return (try await client.copy(file.id, to: parent, name: name, operationID: operationID), false)
        }
        var receipt = try transferReceipt(result.0, in: folder); receipt.sourceRemoved = result.1; return receipt
    }
    public func recoverTransfer(_ operation: UUID, in folder: URL) throws -> CloudTransferReceipt? {
        guard let client, let record = try client.mutationJournal.load(operation) else { return nil }
        let result: DriveFile?
        if record.result != nil {
            result = record.result
        } else if record.kind == "copy" || record.kind == "createFolder" || record.kind == "upload" || record.kind == "replace" {
            result = try CloudAwait.run { try await client.reconcile(record) }
        } else {
            return nil
        }
        guard let result else { return nil }
        if record.result == nil, record.kind == "upload" || record.kind == "replace" {
            guard result.appProperties?["porpoiseOperation"] == operation.uuidString else { return nil }
            guard let local = record.localSource, let fingerprint = record.fingerprint, JobJournal.Fingerprint(local) == fingerprint,
                result.size.flatMap(Int64.init) == fingerprint.size, result.md5Checksum == (try DriveClient.md5(local))
            else { throw DriveMutationError.sourceChanged }
        }
        var receipt = try transferReceipt(result, in: folder); receipt.sourceRemoved = record.kind == "move"; return receipt
    }
    private func transferReceipt(_ file: DriveFile, in folder: URL) throws -> CloudTransferReceipt {
        let receipt = CloudTransferReceipt(
            url: file.childLocation(in: try location(folder)).url, snapshot: driveTransferSnapshot(file, account: accountID))
        try verifyTransfer(receipt); return receipt
    }
    public func verifyTransfer(_ receipt: CloudTransferReceipt) throws {
        guard let client, let expected = receipt.snapshot else { throw DriveMutationError.sourceChanged }
        let fresh = try CloudAwait.run { try await client.file(expected.item.ref.item) }
        guard expected.matches(driveTransferSnapshot(fresh, account: accountID)) else { throw DriveMutationError.sourceChanged }
    }
    public func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL {
        try download(source, into: folder, operationID: operationID)
    }
    public func removeTransferredSource(_ source: URL, snapshot: CloudTransferSnapshot?, revision: String?) throws {
        guard let client else { throw DriveError.reconnect }
        guard case .folder(let id, _) = try location(source).collection else { throw DriveError.invalidLocation }
        let file = try CloudAwait.run { try await client.file(id) }
        let fresh = driveTransferSnapshot(file, account: accountID)
        guard snapshot.map({ $0.matches(fresh) }) ?? (revision == fresh.item.revision) else { throw DriveMutationError.sourceChanged }
        _ = try CloudAwait.run { try await client.setTrashed(fresh.item.ref.item, trashed: true) }
    }
    public func cancelTransferredOperation(_ operation: UUID, at url: URL) throws {
        guard let client else { throw DriveError.reconnect }
        if try client.mutationJournal.load(operation)?.kind == "download" {
            try client.mutationJournal.claim(operation); defer { client.mutationJournal.release(operation) }
            guard var record = try client.mutationJournal.load(operation) else { return }
            let partial = client.mutationJournal.partial(operation)
            guard record.destinationURL == nil || record.destinationURL == partial else { throw DriveMutationError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(partial, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw DriveMutationError.sourceChanged
            }
            record.phase = .prepared; record.destinationURL = nil; record.fingerprint = nil; record.downloadRanges = nil; record.offset = 0
            try client.mutationJournal.save(record)
        } else {
            try CloudAwait.run { try await client.cancelTransfer(operation) }
        }
    }
}

private func driveTransferSnapshot(_ file: DriveFile, account: UUID) -> CloudTransferSnapshot {
    CloudTransferSnapshot(
        item: CloudRemoteItem(
            ref: .init(account: account.uuidString.lowercased(), item: file.id), name: file.name,
            parents: file.parents ?? [], isFolder: file.isFolder, size: file.size.flatMap(Int64.init), revision: file.version,
            checksum: file.md5Checksum.map(CloudChecksum.md5)), headRevision: file.headRevisionId,
        nativeType: file.isGoogleDocument ? file.mimeType : nil)
}
