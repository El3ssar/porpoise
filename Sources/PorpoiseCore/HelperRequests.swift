import Foundation

/// What the privileged helper does with a request, apart from XPC and finding out who asked: checking it and running
/// the tool. Kept here so it can be tested in-process, without root or launchd.
public enum HelperRequests {
    /// Why the helper won't run `arguments` (the tool first), or nil when it's one of `PorpoiseHelperInfo.allowedTools`.
    public static func refusal(_ arguments: [String]) -> String? {
        guard let tool = arguments.first, PorpoiseHelperInfo.allowedTools.contains(tool) else {
            return "Porpoise's helper doesn't run \(arguments.first ?? "nothing")."
        }
        return nil
    }

    /// The command that makes user `uid` (group `gid`, home folder `home`) the owner of `path`, or nil unless the item
    /// sits directly in that user's Trash and isn't a symlink (chown would change its target).
    public static func ownershipCommand(path: String, uid: UInt32, gid: UInt32, home: String) -> [String]? {
        let item = URL(fileURLWithPath: path)
        let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().path
        let homeTrash = URL(fileURLWithPath: home).appendingPathComponent(".Trash").resolvingSymlinksInPath().path
        // The item itself, named exactly: "link/" or "link//" would make lstat (and resolving) follow a symlink.
        let target = parent + "/" + (path as NSString).lastPathComponent
        var st = stat()
        guard PorpoiseHelperInfo.isInUsersTrash(path: path, resolvedParent: parent, uid: uid, resolvedHomeTrash: homeTrash),
            lstat(target, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK
        else { return nil }
        // -P (the default with -R): symlinks inside are changed themselves, never followed.
        return ["/usr/sbin/chown", "-R", "-P", "\(uid):\(gid)", target]
    }

    /// Runs a tool (no shell); nil on success, else what went wrong.
    public static func run(_ arguments: [String]) -> String? {
        guard let tool = arguments.first else { return "Porpoise's helper doesn't run nothing." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = Array(arguments.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : (msg.isEmpty ? "\(tool) failed." : msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
