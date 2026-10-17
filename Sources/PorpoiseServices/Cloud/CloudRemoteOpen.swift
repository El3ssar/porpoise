import Foundation
import PorpoiseCore

/// Provider-neutral opening pipeline: a current local copy opens immediately; a miss is a normal Activity transfer.
public enum CloudRemoteOpen {
    @MainActor public static func prepare(
        _ item: FileItem, cached: URL? = nil, operations: FileOperationsController = .shared,
        load: @escaping (CloudTransferContext) async throws -> URL
    ) async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        return try await operations.downloadForOpening(item, load: load)
    }
}

/// Pause/cancel at bounded chunk boundaries. Activity owns scheduling and presents byte progress/ETA.
public struct CloudTransferContext: Sendable {
    public var checkpoint: @Sendable () async throws -> Void
    public var progress: @Sendable (Int64, Int64) -> Void
    public var status: @Sendable (String?) -> Void
    public init(
        checkpoint: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() },
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
        status: @escaping @Sendable (String?) -> Void = { _ in }
    ) { self.checkpoint = checkpoint; self.progress = progress; self.status = status }
}
