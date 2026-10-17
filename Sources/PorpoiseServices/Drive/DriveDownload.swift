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
            return (partial, name, target)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard record.offset == 0, record.downloadRanges == nil else { throw DriveMutationError.sourceChanged }
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DriveError.invalidResponse
            }
        }
        if let fingerprint = record.fingerprint, fingerprint.inode != JobJournal.Fingerprint(partial)?.inode {
            throw DriveMutationError.sourceChanged
        }
        record.fingerprint = JobJournal.Fingerprint(partial)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        // A torn uncheckpointed chunk is discarded; bytes after the journal offset were never confirmed.
        guard (try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) >= record.offset else { throw DriveMutationError.sourceChanged }
        if record.downloadRanges == nil {
            try output.truncate(atOffset: UInt64(record.offset)); try output.seek(toOffset: UInt64(record.offset))
        }
        record.phase = .transferring; try mutationJournal.save(record)
        if target.isGoogleDocument {
            try await context.checkpoint()
            let result = try await download(target, preset: preset)
            guard result.data.count <= 10 * 1024 * 1024 else { throw DriveError.exportTooLarge }
            try output.write(contentsOf: result.data); try output.synchronize()
            record.offset = Int64(result.data.count)
        } else {
            guard let total = target.size.flatMap(Int64.init), total >= 0 else { throw DriveError.invalidResponse }
            if total >= 32 * 1024 * 1024, maximumConnections > 1 || record.downloadRanges != nil {
                record = try await parallelDownload(
                    target, total: total, partial: partial, record: record, context: context, maximumConnections: maximumConnections)
            } else {
                let start = record.offset
                let ranged = total >= 8 * 1024 * 1024 || start > 0
                var received = start
                var buffered = Data()
                var checkpointAt = Date()
                var progressAt = Date.distantPast
                context.progress(received, total)
                do {
                    if received < total {
                        let (_, response) = try await mutationResponse(
                            mutationURL("files/\(target.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                            headers: ranged ? ["Range": "bytes=\(start)-\(total - 1)"] : [:], context: context,
                            receive: { data, response in
                                guard
                                    ranged
                                        ? response.statusCode == 206
                                            && response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(total - 1)/\(total)"
                                        : response.statusCode == 200,
                                    received + Int64(data.count) <= total
                                else { throw DriveError.invalidResponse }
                                try await context.checkpoint()
                                buffered.append(data)
                                received += Int64(data.count)
                                if buffered.count >= 1024 * 1024 {
                                    try output.write(contentsOf: buffered)
                                    buffered.removeAll(keepingCapacity: true)
                                }
                                if received - record.offset >= 8 * 1024 * 1024 || Date().timeIntervalSince(checkpointAt) >= 2 {
                                    try output.write(contentsOf: buffered); buffered.removeAll(keepingCapacity: true)
                                    try output.synchronize()
                                    record.offset = received; record.fingerprint = JobJournal.Fingerprint(partial)
                                    try self.mutationJournal.save(record); checkpointAt = Date()
                                }
                                if received == total || Date().timeIntervalSince(progressAt) >= 0.1 {
                                    context.progress(received, total); progressAt = Date()
                                }
                            })
                        guard response.statusCode == (ranged ? 206 : 200), received == total else { throw DriveError.invalidResponse }
                    }
                } catch {
                    // Keep only durable bytes. Cleanup and resume can still authenticate the owned partial.
                    try output.truncate(atOffset: UInt64(record.offset)); try output.synchronize()
                    record.fingerprint = JobJournal.Fingerprint(partial); try mutationJournal.save(record)
                    throw error
                }
                try output.write(contentsOf: buffered); try output.synchronize()
                record.offset = received; record.fingerprint = JobJournal.Fingerprint(partial)
                try mutationJournal.save(record)
            }
            if let checksum = target.md5Checksum, try Self.md5(partial) != checksum { throw DriveError.invalidResponse }
        }
        let fresh = try await self.file(target.id, resourceKey: target.resourceKey)
        guard fresh.version == record.revision, fresh.headRevisionId == target.headRevisionId, fresh.md5Checksum == target.md5Checksum,
            fresh.size == target.size
        else {
            throw DriveMutationError.sourceChanged
        }
        record.destinationURL = partial; record.fingerprint = JobJournal.Fingerprint(partial); record.phase = .done
        try mutationJournal.save(record)
        context.progress(record.offset, record.offset)
        return (partial, name, fresh)
    }
}
