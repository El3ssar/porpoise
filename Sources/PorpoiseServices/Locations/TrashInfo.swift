import Foundation
import PorpoiseCore

/// The user's own Trash (Dolphin's trash:/), and Finder's "Remove items from the Trash after 30 days" preference.
public enum TrashInfo {
    public static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    public static func summary() -> String { summary(of: folder) }

    static func summary(of t: URL) -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: t.path) else {
            return "The Trash can be shown once Porpoise has Full Disk Access (System Settings › Privacy & Security)."
        }
        let items = names.filter { $0 != ".DS_Store" }
        let size = items.reduce(Int64(0)) { $0 + FileJob.diskSize(t.appendingPathComponent($1)) }
        return items.isEmpty ? "The Trash is empty." : "\(FileFormat.itemCount(items.count)) in the Trash, \(FileFormat.size(size))."
    }

    /// Nothing in the Trash (or it can't be read without Full Disk Access).
    public static var isEmpty: Bool { isEmpty(folder) }

    /// Read again only when the folder's date changes (menus ask on every check), and only until a first entry.
    static func isEmpty(_ trash: URL) -> Bool {
        var st = stat()
        guard stat(trash.path, &st) == 0 else { return true }
        let modified = st.st_mtimespec
        if let c = cacheLock.withLock({ emptyCache[trash.path] }), c.sec == modified.tv_sec, c.nsec == modified.tv_nsec { return c.empty }
        var empty = true
        if let d = opendir(trash.path) {
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name != "." && name != ".." && name != ".DS_Store" {
                    empty = false
                    break
                }
            }
            closedir(d)
        }
        cacheLock.withLock { emptyCache[trash.path] = (modified.tv_sec, modified.tv_nsec, empty) }
        return empty
    }

    /// Guarded by `cacheLock`.
    nonisolated(unsafe) private static var emptyCache: [String: (sec: Int, nsec: Int, empty: Bool)] = [:]
    private static let cacheLock = NSLock()

    public static var autoEmpty: Bool {
        get { CFPreferencesCopyAppValue("FXRemoveOldTrashItems" as CFString, "com.apple.finder" as CFString) as? Bool ?? false }
        set {
            CFPreferencesSetAppValue("FXRemoveOldTrashItems" as CFString, newValue as CFBoolean, "com.apple.finder" as CFString)
            CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        }
    }
}
