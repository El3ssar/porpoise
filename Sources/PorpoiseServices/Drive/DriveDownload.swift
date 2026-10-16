import Foundation
import PorpoiseCore

extension DriveClient {
    /// A private, job-owned partial. Ranges are accepted only for the recorded revision and exact response range.
    public func downloadToStaging(
        _ file: DriveFile, preset: DriveExportPreset = .office, operationID: UUID = UUID(), context: DriveTransferContext = .init()
    ) async throws -> (url: URL, name: String) {
        let target = try await resolve(self.file(file.id, resourceKey: file.resourceKey))
        guard target.operations.canDownload || target.operations.canExport else { throw DriveError.permissionDenied }
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        let directory = mutationJournal.folder.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = directory.appendingPathComponent(operationID.uuidString + ".part")
        var record =
            try mutationJournal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: "download", sourceID: target.id)
        guard record.accountID == accountID, record.sourceID == target.id, record.kind == "download" else { throw DriveMutationError.conflict }
        if record.phase != .prepared, record.revision != target.version { throw DriveMutationError.sourceChanged }
        record.revision = target.version
        let name: String
        if target.isGoogleDocument {
            guard let format = preset.format(for: target.mimeType) else { throw DriveError.unsupportedExport }
            name = file.name + "." + format.fileExtension
        } else {
            name = file.name
        }
        try RemoteFS.checkName(name)
        if record.phase == .done, record.destinationURL == partial,
            JobJournal.Fingerprint(partial) == record.fingerprint
        {
            return (partial, name)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard record.offset == 0 else { throw DriveMutationError.sourceChanged }
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DriveError.invalidResponse
            }
        }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        // A torn uncheckpointed chunk is discarded; bytes after the journal offset were never confirmed.
        guard (try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) >= record.offset else { throw DriveMutationError.sourceChanged }
        try output.truncate(atOffset: UInt64(record.offset)); try output.seek(toOffset: UInt64(record.offset))
        record.phase = .transferring; try mutationJournal.save(record)
        if target.isGoogleDocument {
            try await context.checkpoint()
            let result = try await download(target, preset: preset)
            guard result.data.count <= 10 * 1024 * 1024 else { throw DriveError.exportTooLarge }
            try output.write(contentsOf: result.data); try output.synchronize()
            record.offset = Int64(result.data.count)
        } else {
            guard let total = target.size.flatMap(Int64.init), total >= 0 else { throw DriveError.invalidResponse }
            while record.offset < total {
                try await context.checkpoint()
                let fresh = try await self.file(target.id, resourceKey: target.resourceKey)
                guard fresh.version == target.version, fresh.md5Checksum == target.md5Checksum, fresh.size == target.size else {
                    throw DriveMutationError.sourceChanged
                }
                let end = min(total - 1, record.offset + 256 * 1024 - 1)
                let (data, response) = try await mutationResponse(
                    mutationURL("files/\(target.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                    headers: ["Range": "bytes=\(record.offset)-\(end)"])
                guard response.statusCode == 206, data.count == end - record.offset + 1,
                    response.value(forHTTPHeaderField: "Content-Range") == "bytes \(record.offset)-\(end)/\(total)"
                else { throw DriveError.invalidResponse }
                try output.write(contentsOf: data); try output.synchronize()
                record.offset += Int64(data.count); try mutationJournal.save(record)
                context.progress(record.offset, total)
            }
            if let checksum = target.md5Checksum, try Self.md5(partial) != checksum { throw DriveError.invalidResponse }
        }
        let fresh = try await self.file(target.id, resourceKey: target.resourceKey)
        guard fresh.version == record.revision else { throw DriveMutationError.sourceChanged }
        record.destinationURL = partial; record.fingerprint = JobJournal.Fingerprint(partial); record.phase = .done
        try mutationJournal.save(record)
        context.progress(record.offset, record.offset)
        return (partial, name)
    }
}
