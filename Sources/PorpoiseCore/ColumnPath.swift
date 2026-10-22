import Foundation

/// The folders a Column view shows, from its first column to the focused one: `root`, then each folder below it down
/// to the location. Works for any URL with a path (a local folder, sftp://host/path, a cloud account's folders).
public enum ColumnPath {
    /// `root` and every folder from it down to `location`, in order; nil when `location` is not `root` or below it.
    public static func chain(from root: URL, to location: URL) -> [URL]? {
        let r = normalized(root), l = normalized(location)
        guard sameServer(r, l) else { return nil }
        let rp = components(r), lp = components(l)
        guard lp.count >= rp.count, Array(lp.prefix(rp.count)) == rp else { return nil }
        var out = [root]
        var u = root
        for name in lp.dropFirst(rp.count) {
            u = u.appendingPathComponent(name, isDirectory: true)
            out.append(u)
        }
        return out
    }

    /// Whether `url` is `root` or a folder below it.
    public static func contains(_ root: URL, _ url: URL) -> Bool { chain(from: root, to: url) != nil }

    private static func normalized(_ u: URL) -> URL { u.isFileURL ? u.standardizedFileURL : u }

    private static func sameServer(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
            && a.user == b.user
    }

    private static func components(_ u: URL) -> [String] { u.pathComponents.filter { $0 != "/" } }
}
