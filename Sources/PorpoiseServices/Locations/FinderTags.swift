import Foundation

/// Finder tags: names plus Finder's color index, read from the `_kMDItemUserTags` extended attribute
/// ("Name\n6"), which is where Finder keeps each tag's color.
public enum FinderTags {
    public struct Tag: Equatable {
        public var name: String
        public var color: Int
    }

    /// Finder's standard tags with their label color numbers.
    public static let standard: [Tag] = [
        Tag(name: "Red", color: 6), Tag(name: "Orange", color: 7), Tag(name: "Yellow", color: 5), Tag(name: "Green", color: 2),
        Tag(name: "Blue", color: 4), Tag(name: "Purple", color: 3), Tag(name: "Gray", color: 1),
    ]

    public static func read(_ url: URL) -> [Tag] {
        guard url.isFileURL else { return [] }
        let name = "com.apple.metadata:_kMDItemUserTags"
        let len = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let got = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        guard got > 0 else { return [] }
        data.count = got   // the attribute may have shrunk between the two calls
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1)
            let n = String(parts.first ?? "")
            let c = parts.count > 1 ? Int(parts[1]) ?? 0 : (standard.first { $0.name == n }?.color ?? 0)
            return Tag(name: n, color: c)
        }
    }

    /// Writes tag names; macOS assigns the standard colors itself.
    public static func set(_ names: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    public static func url(for tag: String) -> URL { URL(string: "tags:/" + (tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag))! }
}
