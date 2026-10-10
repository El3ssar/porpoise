import Foundation
import PorpoiseCore

/// The user's own Trash (Dolphin's trash:/), and Finder's "Remove items from the Trash after 30 days" preference.
public enum TrashInfo {
    public static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    public static func summary() -> String {
        let t = folder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: t.path) else {
            return "The Trash can be shown once Porpoise has Full Disk Access (System Settings › Privacy & Security)."
        }
        let items = names.filter { $0 != ".DS_Store" }
        let size = items.reduce(Int64(0)) { $0 + FileJob.diskSize(t.appendingPathComponent($1)) }
        return items.isEmpty ? "The Trash is empty." : "\(FileFormat.itemCount(items.count)) in the Trash, \(FileFormat.size(size))."
    }

    /// Nothing in the Trash (or it can't be read without Full Disk Access).
    public static var isEmpty: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    public static var autoEmpty: Bool {
        get { CFPreferencesCopyAppValue("FXRemoveOldTrashItems" as CFString, "com.apple.finder" as CFString) as? Bool ?? false }
        set {
            CFPreferencesSetAppValue("FXRemoveOldTrashItems" as CFString, newValue as CFBoolean, "com.apple.finder" as CFString)
            CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        }
    }
}
