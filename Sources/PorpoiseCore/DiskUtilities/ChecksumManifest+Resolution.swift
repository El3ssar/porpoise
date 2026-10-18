import Foundation

extension ChecksumManifest {
    public static func resolve(_ entry: ChecksumEntry, below root: URL) throws -> URL {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.path.hasPrefix("/"), !components.contains(".."), !entry.path.contains("\0") else {
            throw Invalid(line: 0, reason: "path escapes manifest folder")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(entry.path).standardizedFileURL
        guard FilePath.contains(path: url.resolvingSymlinksInPath().path, in: base.path) else {
            throw Invalid(line: 0, reason: "symlink escapes manifest folder")
        }
        return url
    }
}
