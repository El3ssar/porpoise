import Foundation

public enum LinkedBrowsing {
    public static func sideNames(_ left: URL, _ right: URL) -> (String, String) {
        let l = left.lastPathComponent.isEmpty ? "/" : left.lastPathComponent
        let r = right.lastPathComponent.isEmpty ? "/" : right.lastPathComponent
        guard l == r else { return (l, r) }
        if left.scheme == right.scheme, left.host == right.host, left.user == right.user, left.port == right.port,
            left.standardized.path == right.standardized.path
        {
            return (l + " (left)", r + " (right)")
        }
        if left.host != right.host { return (left.host ?? l, right.host ?? r) }
        let lc = Array(left.standardized.pathComponents.dropLast().reversed())
        let rc = Array(right.standardized.pathComponents.dropLast().reversed())
        for depth in 0..<max(lc.count, rc.count) {
            let a = depth < lc.count ? lc[depth] : "/", b = depth < rc.count ? rc[depth] : "/"
            if a != b { return (a, b) }
        }
        return (l + " (left)", r + " (right)")
    }

    /// Follow a descendant relative to the anchors, or mirror an upward step beyond them.
    /// Unrelated path edits establish a fresh anchor pair instead of jumping to an arbitrary folder.
    public static func counterpart(_ url: URL, sourceRoot: URL, targetRoot: URL) -> URL? {
        if let relative = relativePath(url, below: sourceRoot) {
            return relative.isEmpty ? targetRoot : targetRoot.appendingPathComponent(relative)
        }
        guard let relative = relativePath(sourceRoot, below: url), !relative.isEmpty else { return nil }
        var target = targetRoot
        for _ in relative.split(separator: "/") {
            guard target.path != "/" else { return nil }
            target.deleteLastPathComponent()
        }
        return target
    }
    /// nil means navigation left the linked roots; empty means the root itself. No disk access.
    public static func relativePath(_ url: URL, below root: URL) -> String? {
        guard url.scheme == root.scheme, url.host == root.host, url.user == root.user, url.port == root.port else { return nil }
        let path = url.standardized.pathComponents, base = root.standardized.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return nil }
        return path.dropFirst(base.count).joined(separator: "/")
    }
}
