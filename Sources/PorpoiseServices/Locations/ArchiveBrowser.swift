import CryptoKit
import Foundation
import PorpoiseCore

/// "Browse compressed files as folders": archives open as a read-only extracted copy in the cache.
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

    /// Extracts once per archive version into the cache. The folder name is a stable digest of the path
    /// (String.hashValue changes every launch, which defeated the cache and piled up copies), and
    /// extraction happens in a temporary folder that is renamed into place only when complete, so an
    /// interrupted extraction is never mistaken for a finished one.
    public static func extractedFolder(for item: FileItem, completion: @escaping (Result<URL, Error>) -> Void) {
        extractedFolder(for: item, in: Settings.cachesFolder.appendingPathComponent("archives"), completion: completion)
    }

    /// The same, with the extracted copies kept in `cache` (tests use their own folder).
    static func extractedFolder(for item: FileItem, in cache: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let stamp = Int(item.modificationDate?.timeIntervalSince1970 ?? 0)
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
                // bsdtar (libarchive) reads zip, tar.*, 7z, rar, iso, xar, cpio… and by default refuses
                // absolute paths, ".." and extracting through symlinks.
                let r = try Shell.run("/usr/bin/tar", ["-xf", item.url.path, "-C", partial.path])
                if r.status != 0 { throw RemoteError.failed(r.err.isEmpty ? "Could not read the archive." : r.err) }
                do {
                    try FileManager.default.moveItem(at: partial, to: dir)
                } catch  where FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.removeItem(at: partial)  // extracted concurrently by another request
                }
                DispatchQueue.main.async { completion(.success(dir)) }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
