import Foundation
import Darwin
import PorpoiseCore

/// Physical walk: never follows symlinks or crosses into a volume the user has not explicitly selected.
/// readdir + lstat avoids URL resource dictionaries; one walk per enabled root runs on a worker queue.
public enum IndexCrawler {
    public static func crawl(_ root: String, exclusions: [String], content: Bool = false,
                             cancelled: () -> Bool = { false }, skip: (String) -> Bool = { _ in false }) -> NameIndex {
        var index = NameIndex()
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return index }
        func visit(_ path: String, name: String, parent: UInt32) {
            if cancelled() || skip(path) || exclusions.contains(where: { NameIndex.contains(path: path, in: $0) }) { return }
            var st = stat()
            guard lstat(path, &st) == 0, st.st_dev == rootStat.st_dev else { return }
            let directory = st.st_mode & S_IFMT == S_IFDIR, link = st.st_mode & S_IFMT == S_IFLNK
            var text: String?
            if content && !directory && !link && st.st_size <= 64 * 1024,
                let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), !bytes.contains(0) {
                text = String(data: bytes, encoding: .utf8)
            }
            let id = index.append(name: name, parent: parent, directory: directory, symlink: link,
                                  size: Int64(st.st_size), modified: Double(st.st_mtimespec.tv_sec), content: text)
            guard directory, let dir = opendir(path) else { return }
            defer { closedir(dir) }
            while !cancelled(), let ent = readdir(dir) {
                let child = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                visit((path == "/" ? "" : path) + "/" + child, name: child, parent: id)
            }
        }
        visit(root, name: root, parent: NameIndex.noParent)
        return index
    }
}
