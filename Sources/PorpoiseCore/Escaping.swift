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

}

extension String {
    /// Whether the text has `c` as a code point. String's own `contains` compares Characters, and a combining mark
    /// after "/", a quote or a dot makes one Character of the two: "a/\u{301}b".contains("/") is false.
    package func containsScalar(_ c: Unicode.Scalar) -> Bool { unicodeScalars.contains(c) }

    /// The parts between `c` code points, empty ones left out (see `containsScalar` for why not `split`).
    package func scalarComponents(separatedBy c: Unicode.Scalar) -> [String] {
        unicodeScalars.split(separator: c).map { String(String.UnicodeScalarView($0)) }
    }
}
