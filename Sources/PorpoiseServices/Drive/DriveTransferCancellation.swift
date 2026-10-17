import Foundation
import PorpoiseCore

extension DriveClient {
    /// Explicit cancellation removes only a matching job-owned partial and credential reference.
    /// A completed remote object is preserved, even when the last response was lost.
    public func cancelTransfer(_ operationID: UUID) async throws {
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        guard var record = try mutationJournal.load(operationID), record.accountID == accountID else { return }
        guard record.phase != .committed, record.phase != .done else { return }
        if record.kind == "upload" || record.kind == "replace" {
            if let remote = try await reconcile(record), remote.appProperties?["porpoiseOperation"] == operationID.uuidString {
                record.result = remote; record.phase = .committed; try mutationJournal.save(record)
                try await tokens.removeSession(operationID)
                return
            }
        }
        if record.kind == "download" {
            let partial = mutationJournal.folder.appendingPathComponent("Downloads").appendingPathComponent(operationID.uuidString + ".part")
            if let fingerprint = record.fingerprint, JobJournal.Fingerprint(partial) == fingerprint {
                try FileManager.default.removeItem(at: partial)
            } else if FileManager.default.fileExists(atPath: partial.path) {
                // Changed partials are preserved; a user modification never becomes cleanup permission.
                throw DriveMutationError.sourceChanged
            }
        }
        try await tokens.removeSession(operationID)
        record.offset = 0; record.downloadRanges = nil; record.hasSession = false; record.phase = .prepared;
        record.fingerprint = record.kind == "download" ? nil : record.fingerprint
        try mutationJournal.save(record)
    }
}
