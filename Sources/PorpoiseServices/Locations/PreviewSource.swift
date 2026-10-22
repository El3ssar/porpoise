import Foundation
import PorpoiseCore

/// Where a preview of an item that isn't on this Mac comes from: the cloud service's own thumbnail or preview, or a
/// temporary copy downloaded from a server. Drawing and caching stay with the app's `Thumbnails`.
public enum PreviewSource {
    /// A local file to make a preview from, and the folder to remove once it's made (a downloaded copy's).
    public struct LocalFile: Sendable {
        public let file: URL
        public let cleanup: URL?
    }

    /// Fetches what `url`'s preview is made from. Cloud services give their thumbnail (`thumbnail`) or preview;
    /// a server's file is copied to a temporary folder, one at a time (a folder of photos must not open dozens of
    /// connections). A copy still waiting its turn when the task is cancelled is never fetched.
    public static func localFile(for url: URL, thumbnail: Bool) async throws -> LocalFile {
        guard let provider = RemoteFS.provider(for: url) else { throw CocoaError(.fileNoSuchFile) }
        if let cloud = provider as? CloudFileProvider { return LocalFile(file: try await cloud.preview(url, thumbnail: thumbnail), cleanup: nil) }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloads.async {
                    guard !cancelled.isSet else { return continuation.resume(throwing: CancellationError()) }
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-preview-\(UUID().uuidString)")
                    do {
                        continuation.resume(returning: LocalFile(file: try provider.download(url, into: dir), cleanup: dir))
                    } catch {
                        try? FileManager.default.removeItem(at: dir)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// After a failed preview, when to ask again: a cloud service may answer a moment later; a server's copy that
    /// failed isn't fetched again.
    public static func retryDelay(for url: URL) -> TimeInterval? { LocationKind.of(url).isCloud ? 5 : nil }

    /// Whether `url`'s large preview arrives in steps (a cloud file: first a quick one, then the full file).
    public static func isProgressive(_ url: URL) -> Bool { RemoteFS.provider(for: url) is CloudFileProvider }

    /// A cloud file's large preview: `onPreview` gets each better local version as it arrives.
    public static func progressive(
        _ url: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void
    ) async throws {
        guard let cloud = RemoteFS.provider(for: url) as? CloudFileProvider else { throw CocoaError(.featureUnsupported) }
        try await cloud.progressivePreview(url, context: context, onPreview: onPreview)
    }

    /// Server downloads for previews, one at a time.
    private static let downloads = DispatchQueue(label: "porpoise.remote-previews", qos: .utility, autoreleaseFrequency: .workItem)
}
