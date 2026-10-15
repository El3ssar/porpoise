import Foundation
import Darwin

public enum IndexPath {
    /// realpath of the nearest existing ancestor + missing suffix. Stable across create/delete/rename,
    /// unlike standardizedFileURL, whose /private and /var spelling changes when the leaf disappears.
    public static func canonical(_ input: String) -> String {
        let expanded = (input as NSString).expandingTildeInPath
        var path = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var suffix: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.reversed().reduce(base) { ($0 == "/" ? "" : $0) + "/" + $1 }
            }
            if path == "/" || path.isEmpty { return expanded }
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
