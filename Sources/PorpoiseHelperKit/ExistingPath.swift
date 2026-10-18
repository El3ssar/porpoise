import Darwin

/// Strict full-existing-path resolution shared with privileged request validation.
package enum ExistingPath {
    /// Resolve only when the entire path exists. Helper validation uses this without weakening its fd checks.
    package static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

}
