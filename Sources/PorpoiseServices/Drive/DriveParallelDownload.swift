import Foundation
import PorpoiseCore

extension DriveMutationRecord: CloudRangeDownloadRecord {}

extension DriveClient {
    func parallelDownload(
        _ file: DriveFile, total: Int64, partial: URL, record: DriveMutationRecord, context: DriveTransferContext, maximumConnections: Int
    ) async throws -> DriveMutationRecord {
        do {
            return try await CloudRangeDownload.run(
                total: total, partial: partial, record: record, context: context, maximumConnections: maximumConnections,
                save: { try self.mutationJournal.save($0) },
                fetch: { range, receive in
                    try await self.mutationResponse(
                        self.mutationURL("files/\(file.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                        headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"], context: context, receive: receive
                    ).1
                })
        } catch CloudTransferError.invalidResponse { throw DriveError.invalidResponse } catch CloudTransferError.sourceChanged {
            throw DriveMutationError.sourceChanged
        }
    }
}
