import Darwin
import Foundation
import PorpoiseCore

/// What a search looked for: with `contents`, results are grouped into name and content matches.
public struct SearchMatches {
    public let text: String
    public let contents: Bool
    private let spec: SearchSpec?
    /// For files found by their contents, the line that contains the text.
    public var snippets: [URL: String]
    /// The snippets are exactly the files found by contents only (worked out while searching, off the main thread):
    /// telling the groups apart is then a lookup, not a comparison of each name.
    public var snippetsMarkContentMatches: Bool

    public init(text: String, contents: Bool, snippets: [URL: String] = [:], snippetsMarkContentMatches: Bool = false) {
        self.text = text
        spec = try? SearchSpec(text, contents: contents)
        self.contents = contents
        self.snippets = snippets
        self.snippetsMarkContentMatches = snippetsMarkContentMatches
    }

    public func nameMatches(_ item: FileItem) -> Bool {
        if snippetsMarkContentMatches { return snippets[item.url] == nil }
        return spec?.nameMatches(item.name) ?? false
    }
}

// The index records physical entries: directories have no file-data length and links keep their own metadata.
extension SearchSpec {
    func metadataMatches(_ item: FileItem) -> Bool {
        let directory = item.isDirectory && !item.isSymlink
        var size = directory ? 0 : item.size, modified = item.modificationDate
        if item.isSymlink {
            var info = stat()
            guard lstat(item.url.path, &info) == 0 else { return false }
            size = Int64(info.st_size); modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        }
        return metadataMatches(path: item.url.path, isDirectory: directory, size: size, modified: modified)
    }
}
