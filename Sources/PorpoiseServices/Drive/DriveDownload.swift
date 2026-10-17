import Foundation
import PorpoiseCore

extension DriveClient {
    /// A private, job-owned partial. Ranges are accepted only for the recorded revision and exact response range.
    public func downloadToStaging(
        _ file: DriveFile, preset: DriveExportPreset = .office, operationID: UUID = UUID(), context: DriveTransferContext = .init(),
        maximumConnections: Int = 8
    ) async throws -> (url: URL, name: String, file: DriveFile) {
        let snapshotSize = file.size.flatMap(Int64.init)
        let snapshot =
            !file.isGoogleDocument && file.shortcutDetails == nil && file.version != nil && file.md5Checksum != nil
            && snapshotSize.map { $0 >= 0 && $0 < 8 * 1024 * 1024 } == true
        let source: DriveFile
        if snapshot { source = file } else { source = try await self.file(file.id, resourceKey: file.resourceKey) }
        let target = try await resolve(source)
        guard target.operations.canDownload || target.operations.canExport else { throw DriveError.permissionDenied }
        let remoteName: String
        let transfer: CloudStagedDownload.Transfer
        if target.isGoogleDocument {
            guard let format = preset.format(for: target.mimeType) else { throw DriveError.unsupportedExport }
            remoteName = file.name + "." + format.fileExtension
            transfer = .data(load: {
                let bytes = try await self.download(target, preset: preset).data
                guard bytes.count <= 10 * 1024 * 1024 else { throw DriveError.exportTooLarge }
                return bytes
            })
        } else {
            remoteName = file.name
            guard let total = target.size.flatMap(Int64.init), total >= 0 else { throw DriveError.invalidResponse }
            transfer = .binary(total: total, connections: maximumConnections, ranges: total >= 32 << 20 && maximumConnections > 1)
        }
        let name = try RemoteFS.localName(remoteName)
        do {
            let (url, fresh) = try await CloudStagedDownload.run(
                journal: mutationJournal, operationID: operationID, context: context, transfer: transfer,
                checksum: target.isGoogleDocument ? nil : target.md5Checksum.map(CloudChecksum.md5), exactFingerprint: false,
                prepare: { existing in
                    var record =
                        existing ?? DriveMutationRecord(operationID: operationID, accountID: self.accountID, kind: "download", sourceID: target.id)
                    guard record.accountID == self.accountID, record.sourceID == target.id, record.kind == "download" else {
                        throw DriveMutationError.conflict
                    }
                    if record.phase != .prepared, record.revision != target.version { throw DriveMutationError.sourceChanged }
                    record.revision = target.version; return record
                },
                fetch: { range, receive in
                    try await self.mutationResponse(
                        self.mutationURL("files/\(target.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                        headers: range.map { ["Range": "bytes=\($0.lowerBound)-\($0.upperBound - 1)"] } ?? [:],
                        context: context, receive: receive
                    ).1
                },
                verify: {
                    let fresh = try await self.file(target.id, resourceKey: target.resourceKey)
                    guard fresh.version == target.version, fresh.headRevisionId == target.headRevisionId,
                        fresh.md5Checksum == target.md5Checksum, fresh.size == target.size
                    else { throw DriveMutationError.sourceChanged }
                    return fresh
                }, finish: { _, _ in })
            return (url, name, fresh)
        } catch CloudTransferError.invalidResponse { throw DriveError.invalidResponse } catch CloudTransferError.sourceChanged {
            throw DriveMutationError.sourceChanged
        } catch CloudContentError.checksum { throw DriveError.invalidResponse }
    }
}
