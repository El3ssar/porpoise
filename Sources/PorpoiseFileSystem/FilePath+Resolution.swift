import Foundation
import PorpoiseCore
import PorpoiseHelperKit

extension FilePath {
    public init(canonical url: URL) { self.init(resolvedPath: Self.canonical(url.path)) }
    public init(entry url: URL) { self.init(resolvedPath: Self.entry(url.path)) }
    public static func sameItem(_ lhs: URL, _ rhs: URL) -> Bool { key(lhs) == key(rhs) }
    public static func key(_ url: URL) -> String { url.isFileURL ? entry(url.path) : url.absoluteString }

    /// Resolve each shared parent once for a listing; callers discard the result when their rows change.
    public static func keys(_ urls: [URL]) -> [String] {
        var parents: [String: String] = [:]
        return urls.map { url in
            guard url.isFileURL else { return url.absoluteString }
            return entry(
                url.path,
                resolveParent: { path in
                    if let known = parents[path] { return known }
                    let resolved = canonical(path); parents[path] = resolved
                    return resolved
                })
        }
    }

    public static func entry(_ input: String) -> String { entry(input, resolveParent: canonical) }

    private static func entry(_ input: String, resolveParent: (String) -> String) -> String {
        if input == "/" { return "/" }
        let path = input.hasSuffix("/") ? String(input.dropLast()) : input
        let parent = resolveParent((path as NSString).deletingLastPathComponent)
        return (parent == "/" ? "" : parent) + "/" + (path as NSString).lastPathComponent
    }

    /// Resolve only when the entire path exists.
    public static func existing(_ path: String) -> String? { ExistingPath.resolve(path) }

    /// realpath of the nearest existing ancestor plus the missing suffix, stable across create/delete/rename.
    public static func canonical(_ input: String) -> String {
        let expanded = (input as NSString).expandingTildeInPath
        var path = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var suffix: [String] = []
        while true {
            if let base = existing(path) {
                return suffix.reversed().reduce(base) { path, part in
                    if part == "." { return path }
                    if part == ".." { return path == "/" ? "/" : (path as NSString).deletingLastPathComponent }
                    return (path == "/" ? "" : path) + "/" + part
                }
            }
            if path == "/" || path.isEmpty { return expanded }
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
