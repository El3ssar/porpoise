import Darwin
import Foundation
import PorpoiseCore

/// Physical walk: never follows symlinks or crosses into a volume the user has not explicitly selected.
/// readdir + lstat avoids URL resource dictionaries; one walk per enabled root runs on a worker queue.
public enum IndexCrawler {
    public static func crawl(
        _ root: String, exclusions: [String], content: Bool = false,
        cancelled: () -> Bool = { false }, unreadable: (String) -> Void = { _ in }, skip: (String) -> Bool = { _ in false }
    ) -> NameIndex {
        var index = NameIndex()
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return index }
        func visit(_ path: String, name: String, parent: UInt32) {
            if cancelled() || skip(path) || exclusions.contains(where: { NameIndex.contains(path: path, in: $0) }) { return }
            var st = stat()
            guard lstat(path, &st) == 0 else {
                if errno == EACCES || errno == EPERM { unreadable(path) }; return
            }
            guard st.st_dev == rootStat.st_dev else { return }
            let directory = st.st_mode & S_IFMT == S_IFDIR, link = st.st_mode & S_IFMT == S_IFLNK
            guard directory || link || st.st_mode & S_IFMT == S_IFREG else { return }
            var text: String?
            if content && !directory && !link && st.st_size <= 64 * 1024 { text = IndexFileText.read(path, limit: 64 * 1024) }
            let id = index.append(
                name: name, parent: parent, directory: directory, symlink: link,
                size: Int64(st.st_size), modified: Double(st.st_mtimespec.tv_sec), content: text)
            // Packages remain one result, matching FolderSearch and the fallback folder walk.
            if directory && parent != NameIndex.noParent,
                (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            {
                return
            }
            guard directory else { return }
            guard let dir = opendir(path) else { unreadable(path); return }
            var children: [String] = []
            while !cancelled(), let ent = readdir(dir) {
                let child = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                children.append(child)
            }
            closedir(dir)
            for child in children {
                visit((path == "/" ? "" : path) + "/" + child, name: child, parent: id)
            }
        }
        visit(root, name: root, parent: NameIndex.noParent)
        return index
    }
}
