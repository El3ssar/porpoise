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
        let full = try await preview(target, context: context)
        try Task.checkCancellation()
        try await show(full)
        return full
    }
}
