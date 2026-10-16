import Foundation
import PorpoiseCore

/// A private comparison snapshot. Remote downloads never share an editor's cache or install upload watchers.
public final class FileComparisonCopies {
    public let left: URL
    public let right: URL
    public let readOnly: Bool
    private let directory: URL?
    private var keepCache = false
    /// External apps may read lazily after this viewer closes; keep their copies in the normal cache.
    public func keepForExternalApplication() { keepCache = true }
    private static let cleanup = DispatchQueue(label: "app.porpoise.comparison-cache-cleanup", qos: .utility)

    /// Blocking downloads: call on a private worker queue. `cacheParent` lets tests isolate their fixtures.
    public init(left: URL, right: URL, cacheParent: URL? = nil, cancellation: DiskCancellation = DiskCancellation()) throws {
        readOnly = !left.isFileURL || !right.isFileURL
        guard readOnly else { self.left = left; self.right = right; directory = nil; return }
        let parent = cacheParent ?? RemoteFS.cacheRoot.appendingPathComponent("Comparisons")
        let folder = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            self.left = try Self.materialize(left, into: folder.appendingPathComponent("Left"), cancellation: cancellation)
            self.right = try Self.materialize(right, into: folder.appendingPathComponent("Right"), cancellation: cancellation)
            directory = folder
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private static func materialize(_ url: URL, into folder: URL, cancellation: DiskCancellation) throws -> URL {
        try cancellation.check()
        if url.isFileURL { return url }
        guard RemoteParsing.isSafeName(url.lastPathComponent), let provider = RemoteFS.provider(for: url) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = try provider.download(url, into: folder)
        try cancellation.check()
        guard local.isFileURL, NameIndex.contains(path: local.resolvingSymlinksInPath().path, in: folder.resolvingSymlinksInPath().path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return local
    }
    deinit {
        if !keepCache, let directory { Self.cleanup.async { try? FileManager.default.removeItem(at: directory) } }
    }
}
