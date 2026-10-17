import Foundation
import PorpoiseCore

/// A selection-owned, loopback-only range proxy. Stop it when the selection or preview closes.
/// Each upstream request is bounded to 1 MiB; no bearer token or Google URL reaches AVPlayer/Quick Look.
public final class DriveStreamingPreview {
    public var url: URL { stream.url }
    private let stream: CloudStreamingPreview

    init(client: DriveClient, file: DriveFile) throws {
        guard !file.isGoogleDocument, file.operations.canDownload, let size = file.size.flatMap(Int64.init), size > 0,
            !file.mimeType.contains("\r"), !file.mimeType.contains("\n")
        else {
            throw DriveError.invalidResponse
        }
        do {
            stream = try CloudStreamingPreview(
                size: size, contentType: file.mimeType,
                read: { range in
                    var path = "files/\(file.id)"
                    // A recorded binary revision is immutable; selecting a newer revision creates a new proxy.
                    if let revision = file.headRevisionId, DriveLink.isValidID(revision) { path += "/revisions/\(revision)" }
                    var url = URLComponents(url: client.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
                    url.queryItems = [URLQueryItem(name: "alt", value: "media")]
                    var data = Data()
                    let (_, response) = try await client.mutationResponse(
                        url.url!,
                        headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"],
                        receive: { chunk, response in
                            guard response.statusCode == 206, data.count + chunk.count <= range.count else { throw DriveError.invalidResponse }
                            data.append(chunk)
                        })
                    guard response.statusCode == 206,
                        response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)",
                        data.count == range.count
                    else { throw DriveError.invalidResponse }
                    return data
                })
        } catch CloudTransferError.invalidResponse { throw DriveError.invalidResponse }
    }

    public func stop() { stream.stop() }
}

extension DriveClient {
    public func streamingPreview(_ file: DriveFile) throws -> DriveStreamingPreview {
        if isOffline { throw DriveError.offline }
        return try DriveStreamingPreview(client: self, file: file)
    }
}
