import Foundation
import PorpoiseCore

public enum DirectoryLister {
    /// Lists a folder (all entries, including hidden ones; the model decides what to show). `cancelled` is asked
    /// between entries: a listing nobody waits for any more (a newer one started) stops early and throws.
    public static func list(_ folder: URL, cancelled: () -> Bool = { false }) throws -> [FileItem] {
        // Names from URLs: the String-based listing drops a leading U+FEFF, which would lose the file. The URL-based
        // one doesn't follow a symlink to a folder, so it is given the real folder; items keep `folder` as named.
        // The attributes come with the listing (one getattrlistbulk pass): asking for each entry's afterwards took
        // about four times as long.
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: FileItem.resourceKeys)
        var items: [FileItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            if cancelled() { throw CancellationError() }
            let name = entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: FileItem.resourceKeySet), let isDirectory = values.isDirectory,
                values.isSymbolicLink == false
            else {
                if let item = FileItem.load(folder.appendingPathComponent(name)) { items.append(item) }
                continue
            }
            // Told whether it's a folder, the URL doesn't stat the entry again to find out.
            if let item = FileItem.load(folder.appendingPathComponent(name, isDirectory: isDirectory), values: values) { items.append(item) }
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
