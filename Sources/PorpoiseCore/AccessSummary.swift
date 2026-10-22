import Foundation

/// What the current user may do with an item, in Finder's words (Get Info › Sharing & Permissions).
public enum AccessSummary {
    public static func text(readable: Bool, writable: Bool) -> String {
        switch (readable, writable) {
        case (true, true): "Read & Write"
        case (true, false): "Read Only"
        case (false, true): "Write Only (Drop Box)"
        case (false, false): "No Access"
        }
    }

    /// The summary for a local item, as the file system answers for this user (ACLs and ownership included).
    public static func text(forFileAt path: String) -> String {
        let fm = FileManager.default
        return text(readable: fm.isReadableFile(atPath: path), writable: fm.isWritableFile(atPath: path))
    }
}
