import Foundation
import PorpoiseCore

public enum DirectoryLister {
    /// Lists a folder (all entries, including hidden ones; the model decides what to show).
    public static func list(_ folder: URL) throws -> [FileItem] {
        // Names from URLs: the String-based listing drops a leading U+FEFF, which would lose the file. The URL-based
        // one doesn't follow a symlink to a folder, so it is given the real folder; items keep `folder` as named.
        let names = try FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        var items: [FileItem] = []
        items.reserveCapacity(names.count)
        for n in names {
            if let item = FileItem.load(folder.appendingPathComponent(n)) { items.append(item) }
        }
        return items
    }

    /// Number of entries in a folder (Dolphin's default "Size" for folders), skipping hidden ones
    /// unless asked.
    public static func childCount(_ folder: URL, includeHidden: Bool) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return includeHidden ? names.count : names.filter { !$0.hasPrefix(".") }.count
    }
}
