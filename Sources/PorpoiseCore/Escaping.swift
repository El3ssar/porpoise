import Foundation

/// Text that ends up inside another language or a URL path: kept here, away from the UI, so it is tested.
public enum Escaping {
    /// An AppleScript string literal for any text: backslashes, quotes and line breaks escaped (a raw line
    /// break, e.g. from a file name, would otherwise end up in the script source).
    public static func appleScriptString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\r\n": out += "\\r\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// Maps an HTTP request target ("/secret/dir/file.m4s?x") to a regular file inside `root`, or nil.
    /// The first component must be `secret`; "..", hidden names, NUL and backslashes are refused (after
    /// percent-decoding), and a symlink resolving outside `root` is refused too. `root` must already be
    /// symlink-resolved.
    public static func servedFile(for target: String, root: URL, secret: String) -> URL? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let decoded = path.removingPercentEncoding else { return nil }
        var comps = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.first == secret else { return nil }
        comps.removeFirst()
        guard !comps.isEmpty, comps.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("\0") && !$0.contains("\\") }) else { return nil }
        let file = comps.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
}
