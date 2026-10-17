import Foundation
import PorpoiseCore

public protocol CloudPreviewStream: AnyObject { var url: URL { get }; func stop() }
extension CloudStreamingPreview: CloudPreviewStream {}
extension DriveStreamingPreview: CloudPreviewStream {}
public struct CloudPlayback {
    public let url: URL
    public let stream: (any CloudPreviewStream)?
    public init(url: URL, stream: (any CloudPreviewStream)? = nil) { self.url = url; self.stream = stream }
}
extension DriveProvider {
    public func playback(_ url: URL) async throws -> CloudPlayback {
        guard let client, let location = DriveLocation(url: url), case .folder(let id, _) = location.collection else {
            throw DriveError.invalidLocation
        }
        let file = try await client.file(id, resourceKey: location.resourceKey)
        if let cached = try await client.cachedPreview(file) { return CloudPlayback(url: cached) }
        let stream = try client.streamingPreview(file); return CloudPlayback(url: stream.url, stream: stream)
    }
}
extension DropboxProvider {
    public func playback(_ url: URL) async throws -> CloudPlayback {
        let client = try scoped(url); let file = try await client.metadata(location(url).itemID)
        let store = try await client.offlineCopies()
        if let cached = await client.cachedPreview(file, store: store) { return CloudPlayback(url: cached) }
        let stream = try client.streamingPreview(
            file, contentType: item(file, client: client).utType?.preferredMIMEType ?? "application/octet-stream")
        return CloudPlayback(url: stream.url, stream: stream)
    }
    public func progressivePreview(
        _ remote: URL, context: CloudTransferContext,
        onPreview: @escaping @MainActor (URL) async throws -> Void
    ) async throws -> URL {
        let client = try scoped(remote); let file = try await client.metadata(location(remote).itemID)
        let store = try await client.offlineCopies()
        if let cached = await client.cachedPreview(file, store: store) { try await onPreview(cached); return cached }
        if let thumbnail = try? await client.thumbnail(file) { try Task.checkCancellation(); try await onPreview(thumbnail) }
        let full = try await client.preview(file, store: store, context: context); try await onPreview(full); return full
    }
}
