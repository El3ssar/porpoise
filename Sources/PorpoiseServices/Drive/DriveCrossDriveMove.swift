import Foundation
import PorpoiseCore

extension DriveClient {
    /// Cross-drive relocation is a recoverable copy/verify/trash transaction; permissions and links follow Drive's copy semantics.
    func crossDriveMove(_ source: DriveFile, parentID: String, operationID: UUID) async throws -> DriveFile {
        guard source.capabilities?.canMoveItemOutOfDrive == true, source.operations.canCopy, !source.isFolder else {
            throw DriveError.permissionDenied
        }
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        var record =
            try mutationJournal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: "crossDriveMove", sourceID: source.id, parentID: parentID)
        guard record.accountID == accountID, record.sourceID == source.id, record.parentID == parentID else { throw DriveMutationError.conflict }
        if record.phase == .done, let result = record.result { return result }
        if record.phase == .sourceRemovalPending {
            // Read-only reconciliation is safe. Never repeat an uncertain source-removal request.
            guard source.trashed == true, let result = record.result else { throw DriveMutationError.uncertain }
            record.phase = .done; try mutationJournal.save(record); return result
        }
        if record.revision == nil { record.revision = source.version }
        guard source.version == record.revision else { throw DriveMutationError.sourceChanged }
        if record.childOperationID == nil { record.childOperationID = UUID(); try mutationJournal.save(record) }
        let copied: DriveFile
        if let result = record.result {
            copied = result
        } else {
            copied = try await copy(source.id, to: parentID, operationID: record.childOperationID!)
            record.result = copied; record.phase = .committed; try mutationJournal.save(record)
        }
        let destination = try await file(copied.id)
        let freshSource = try await file(source.id)
        guard destination.version == copied.version, freshSource.version == record.revision,
            source.mimeType == destination.mimeType,
            source.isGoogleDocument || (source.md5Checksum != nil && source.md5Checksum == destination.md5Checksum && source.size == destination.size)
        else { throw DriveMutationError.sourceChanged }
        record.phase = .sourceRemovalPending; try mutationJournal.save(record)
        _ = try await setTrashed(source.id, trashed: true)
        record.phase = .done; try mutationJournal.save(record)
        return destination
    }
}
