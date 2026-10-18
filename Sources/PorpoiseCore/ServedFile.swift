import Foundation

extension Escaping {
    /// Maps an HTTP request target ("/secret/dir/file.m4s?x") to a regular file inside `root`, or nil.
    /// The first component must be `secret`; "..", hidden names, NUL and backslashes are refused (after
    /// percent-decoding), and a symlink resolving outside `root` is refused too. `root` must already be
    /// symlink-resolved.
    public static func servedFile(for target: String, root: URL, secret: String) -> URL? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let decoded = path.removingPercentEncoding else { return nil }
        var comps = decoded.scalarComponents(separatedBy: "/")
        guard comps.first == secret else { return nil }
        comps.removeFirst()
        guard !comps.isEmpty, comps.allSatisfy({ $0.unicodeScalars.first != "." && !$0.containsScalar("\0") && !$0.containsScalar("\\") })
        else { return nil }
        let file = comps.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
}
