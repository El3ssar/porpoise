import Foundation

/// Filesystem identity independent of /tmp and /private/tmp spelling, including a missing leaf.
/// Use an entry identity when a selected symlink must remain distinct from its target.
public struct FilePath: Hashable, Sendable {
    public let path: String
    public var displayPath: String { path }
    package init(resolvedPath: String) { path = resolvedPath }
    public func contains(_ other: FilePath) -> Bool { Self.contains(path: other.path, in: path) }

    /// Component-boundary containment for paths already resolved by their owner (no IO on indexed paths).
    public static func contains(path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
