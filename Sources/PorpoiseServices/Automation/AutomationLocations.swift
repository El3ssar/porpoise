import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Filesystem preflight for explicit local automation paths. Call on a worker before asking the user.
public enum AutomationLocations {
    public static func localURLs(_ paths: [String], folders: Bool) throws -> [URL] {
        try paths.map { path in
            guard path.hasPrefix("/"), !path.contains("\0") else { throw AutomationError.invalidRequest }
            // Resolve the parent before lexical normalization: a symlink followed by `..` changes where it leads.
            // Keep the leaf itself (copy/move/reveal of a symlink must not silently select its target).
            let url = URL(fileURLWithPath: FilePath.entry(path)).standardizedFileURL
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            if folders {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw AutomationError.invalidRequest
                }
            }
            return url
        }
    }

}
