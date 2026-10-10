import Foundation

/// Text that ends up inside another language or a URL path: kept here, away from the UI, so it is tested.
public enum Escaping {
    /// An AppleScript string literal for any text: backslashes, quotes and line breaks escaped (a raw line
    /// break, e.g. from a file name, would otherwise end up in the script source). By code point: a combining mark
    /// after a quote makes one Character of the two, which a Character comparison would let through unescaped.
    public static func appleScriptString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(u)
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

extension String {
    /// Whether the text has `c` as a code point. String's own `contains` compares Characters, and a combining mark
    /// after "/", a quote or a dot makes one Character of the two: "a/\u{301}b".contains("/") is false.
    func containsScalar(_ c: Unicode.Scalar) -> Bool { unicodeScalars.contains(c) }

    /// The parts between `c` code points, empty ones left out (see `containsScalar` for why not `split`).
    func scalarComponents(separatedBy c: Unicode.Scalar) -> [String] {
        unicodeScalars.split(separator: c).map { String(String.UnicodeScalarView($0)) }
    }
}
