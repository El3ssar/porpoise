import CryptoKit
import Foundation
import PorpoiseCore

/// Local archive locations list in memory; less common formats retain whole-archive extraction as a fallback.
public enum ArchiveBrowser {
    static let extensions: Set<String> = ["zip", "tar", "tgz", "tbz", "txz", "7z", "rar", "iso", "jar", "cpio", "xar"]
    /// Compressors: an archive only as "x.tar.gz" and the like. "log.txt.gz" is one compressed file, which tar can't
    /// extract ("Missing type keyword in mtree specification"): it opens in its application instead.
    static let compressed: Set<String> = ["gz", "bz2", "xz", "zst"]

    public static func isArchive(_ item: FileItem) -> Bool {
        guard !item.isBrowsableFolder else { return false }
        let ext = item.fileExtension.lowercased()
        let n = item.name.lowercased()
        return extensions.contains(ext) || (compressed.contains(ext) && n.dropLast(ext.count + 1).hasSuffix(".tar"))
    }

    /// A location for supported local formats. No I/O and no extraction: the location source lists off-main.
    public static func location(for item: FileItem) -> URL? {
        guard item.url.isFileURL, isArchive(item) else { return nil }
        let name = item.name.lowercased()
        let supported = [".zip", ".jar", ".7z", ".tar", ".tgz", ".tbz", ".txz", ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]
        guard supported.contains(where: { name.hasSuffix($0) }) else { return nil }
        return ArchiveLocation(archive: item.url).url
    }

    /// A fresh extracted file for opening or Quick Look; Activity can supply cancellation and progress.
    @MainActor public static func localCopy(_ url: URL, context: CloudTransferContext = .init()) async throws -> URL {
        guard let provider = RemoteFS.provider(for: url) as? ArchiveProvider else { throw CocoaError(.fileReadInvalidFileName) }
        return try await provider.localCopy(url, context: context, policy: Settings.shared.transferPolicy)
    }

    /// Extracts once per archive version into the cache. The folder name is a stable digest of the path
    /// (String.hashValue changes every launch, which defeated the cache and piled up copies), and
    /// extraction happens in a temporary folder that is renamed into place only when complete, so an
    /// interrupted extraction is never mistaken for a finished one.
    public static func extractedFolder(for item: FileItem, completion: @escaping (Result<URL, Error>) -> Void) {
        extractedFolder(for: item, in: Settings.cachesFolder.appendingPathComponent("archives"), completion: completion)
    }

    /// The same, with the extracted copies kept in `cache` (tests use their own folder).
    static func extractedFolder(for item: FileItem, in cache: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let stamp = ArchiveVersion.at(item.url)?.cacheKey ?? "missing"
        let digest = SHA256.hash(data: Data(item.url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let parent = cache.appendingPathComponent("\(digest)-\(stamp)")
        let dir = parent.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: dir.path) { completion(.success(dir)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Copies extracted from earlier versions of this archive are stale now: free their space.
            for old in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            where old.hasPrefix(digest + "-") && old != parent.lastPathComponent {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent(old))
            }
            let partial = parent.appendingPathComponent(".partial-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
                let index = try ArchiveIndex(item.url)
                _ = try index.extract(nil, into: partial, name: "contents")
                do {
                    try FileManager.default.moveItem(at: partial.appendingPathComponent("contents"), to: dir)
                } catch  where FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.removeItem(at: partial)  // extracted concurrently by another request
                }
                try? FileManager.default.removeItem(at: partial)
                DispatchQueue.main.async { completion(.success(dir)) }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
