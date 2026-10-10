import Foundation

/// Finder's Spotlight comments (kMDItemFinderComment), kept in an extended attribute.
public enum FinderComment {
    private static let attr = "com.apple.metadata:kMDItemFinderComment"

    public static func read(_ url: URL) -> String {
        let len = getxattr(url.path, attr, nil, 0, 0, 0)
        guard len > 0 else { return "" }
        var data = Data(count: len)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, attr, $0.baseAddress, len, 0, 0) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? String) ?? ""
    }

    public static func write(_ text: String, to url: URL) {
        if text.isEmpty { removexattr(url.path, attr, 0); return }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, attr, $0.baseAddress, data.count, 0, 0) }
    }
}
