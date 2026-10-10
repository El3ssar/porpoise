import Foundation

/// Porpoise's privileged helper: a launchd daemon (approved once in System Settings › Login Items) that does the
/// file operations macOS only lets an administrator do, such as moving apps that belong to the system to the
/// Trash. It answers only to Porpoise signed with the same certificate as itself.
@objc public protocol PorpoiseHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Runs one of the file tools in `allowedTools` (no shell) with `arguments` (the tool first). Replies nil on
    /// success, or what went wrong.
    func run(_ arguments: [String], reply: @escaping (String?) -> Void)
    /// Makes the user who asked the owner of an item in their own Trash (the home Trash or a volume's
    /// .Trashes/<uid>), so emptying the Trash later needs no administrator rights. Nothing outside it.
    func takeOwnership(ofTrashed path: String, reply: @escaping (String?) -> Void)
}

public enum PorpoiseHelperInfo {
    public static let machService = "app.porpoise.Porpoise.helper"
    public static let plistName = "app.porpoise.Porpoise.helper.plist"
    public static let appIdentifier = "app.porpoise.Porpoise"
    public static let helperIdentifier = "app.porpoise.Porpoise.helper"
    /// The only programs the helper runs.
    public static let allowedTools: Set<String> = ["/bin/mv", "/bin/cp", "/bin/ln", "/bin/mkdir", "/bin/chmod", "/bin/rm", "/usr/bin/chflags"]

    /// Whether `path` sits directly in user `uid`'s Trash: `home`/.Trash, or a volume's /Volumes/<name>/.Trashes/<uid>.
    /// `resolvedParent` is the item's folder with symlinks resolved (the helper passes the real one).
    public static func isInUsersTrash(path: String, resolvedParent: String, uid: UInt32, resolvedHomeTrash: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        if resolvedParent == resolvedHomeTrash { return true }
        let parts = resolvedParent.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "Volumes", "<name>", ".Trashes", "<uid>"]
        return parts.count == 5 && parts[0].isEmpty && parts[1] == "Volumes" && !parts[2].isEmpty && parts[2] != ".."
            && parts[3] == ".Trashes" && parts[4] == Substring(String(uid))
    }
}
