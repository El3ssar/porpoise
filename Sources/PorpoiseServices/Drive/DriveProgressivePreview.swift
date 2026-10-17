import Foundation
import PorpoiseCore

extension DriveClient {
    /// Paint a cached full copy immediately, otherwise a thumbnail before the verified full rendition.
    /// Awaiting each paint preserves ordering; cancellation propagates through both network stages.
    public func progressivePreview(
        _ file: DriveFile, context: DriveTransferContext = .init(), show: (URL) async throws -> Void
    ) async throws -> URL {
        let target = try await resolve(file)
        if let cached = try await cachedPreview(target) {
            try Task.checkCancellation()
            try await show(cached)
            return cached
        }
        if target.thumbnailLink != nil, target.hasThumbnail != false {
            do {
                let initial = try await thumbnail(target)
                try Task.checkCancellation()
                try await show(initial)
            } catch {
                try Task.checkCancellation()
                // An expired thumbnail link must not prevent the full preview.
            }
        }
        if target.thumbnailLink == nil,
            target.mimeType.hasPrefix("text/") || ["application/json", "application/javascript", "application/xml"].contains(target.mimeType),
            let size = target.size.flatMap(Int64.init), size > 65536
        {
            do {
                let prefix = try await textPrefix(target, size: size)
                try Task.checkCancellation()
                try await show(prefix)
            } catch { try Task.checkCancellation() }
        }
        let full = try await preview(target, context: context)
        try Task.checkCancellation()
        try await show(full)
        return full
    }
    private func textPrefix(_ file: DriveFile, size: Int64) async throws -> URL {
        try await mediaCache.file(key: "text-prefix|\(file.id)|\(file.headRevisionId ?? file.version ?? file.modifiedTime ?? "")", name: file.name) {
            var data = Data()
            let (_, response) = try await self.mutationResponse(
                self.mutationURL("files/\(file.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                headers: ["Range": "bytes=0-65535"],
                receive: { chunk, response in
                    guard response.statusCode == 206, data.count + chunk.count <= 65536 else { throw DriveError.invalidResponse }
                    data.append(chunk)
                })
            guard response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-65535/\(size)", data.count == 65536 else {
                throw DriveError.invalidResponse
            }
            return data
        }
    }

}
