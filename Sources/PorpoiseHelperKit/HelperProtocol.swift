import Foundation

/// Porpoise's privileged helper: a launchd daemon, installed once with the administrator's approval into
/// /Library/PrivilegedHelperTools, that does the file operations macOS only lets an administrator do, such as moving
/// apps that belong to the system to the Trash. It answers only to Porpoise signed with the same certificate as itself.
@objc(_TtP12PorpoiseCore22PorpoiseHelperProtocol_) public protocol PorpoiseHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// One action: `requests` are fixed file-operation arrays in `allowedTools` (identifier first), validated and
    /// classified by the helper, which then asks the person for the right they need (`HelperTier`) on behalf of
    /// `authorization` (Porpoise's, in external form) with a prompt made from them, and runs them on validated
    /// descriptors (never a tool). Afterwards the items it moved to the paths in `handOver` (the person's Trash) are
    /// made theirs, so emptying the Trash needs no administrator. Replies whether the person cancelled, and nil on
    /// success or what went wrong.
    func perform(_ requests: [[String]], authorization: Data, handOver: [String], reply: @escaping (Bool, String?) -> Void)
    /// Whether the helper may read the asking user's Trash, i.e. has Full Disk Access. Asking also lists it (switched
    /// off) under Full Disk Access in System Settings, so the user finds it there.
    func checkFullDiskAccess(reply: @escaping (Bool) -> Void)
}

public enum PorpoiseHelperInfo {
    public static let machService = "app.porpoise.helper"
    /// Where it's installed (outside the app, so app updates never touch it) and its launchd job. It's a small app
    /// bundle, "Porpoise Helper" with Porpoise's icon, so it's recognisable in System Settings' privacy lists.
    public static let installedApp = "/Library/PrivilegedHelperTools/Porpoise Helper.app"
    public static let installedTool = installedApp + "/Contents/MacOS/PorpoiseHelper"
    public static let installedPlist = "/Library/LaunchDaemons/app.porpoise.helper.plist"
    /// The launchd job, written by the install itself (an edited `Program` in a copy from the app's folder would run
    /// anything as root).
    public static let launchdPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>app.porpoise.helper</string>
          <key>Program</key><string>/Library/PrivilegedHelperTools/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper</string>
          <key>MachServices</key><dict><key>app.porpoise.helper</key><true/></dict>
          <key>ThrottleInterval</key><integer>1</integer>
          <key>AssociatedBundleIdentifiers</key><array><string>app.porpoise.Porpoise</string></array>
        </dict></plist>

        """
    /// The bare binary earlier versions installed (removed when the bundle is installed).
    public static let oldInstalledTool = "/Library/PrivilegedHelperTools/app.porpoise.helper"
    public static let appIdentifier = "app.porpoise.Porpoise"
    public static let helperIdentifier = "app.porpoise.Porpoise.helper"
    /// The helper's version: the app installs it again when the installed one is another.
    public static let version = "7"

    /// What the helper must be signed as: its identifier, with `certificateHash` (Porpoise's own leaf certificate).
    public static func helperRequirement(certificateHash: String) -> String {
        "identifier \"\(helperIdentifier)\" and certificate leaf = H\"\(certificateHash)\""
    }
    /// Legacy wire identifiers, decoded into descriptor-bound filesystem operations; never executed as programs.
    public static let allowedTools: Set<String> = [
        "/bin/mv", "/bin/cp", "/bin/ln", "/bin/mkdir", "/bin/chmod", "/bin/rm", "/usr/bin/chflags", "/usr/sbin/chown",
    ]

    /// Whether `path` sits directly in user `uid`'s Trash: `home`/.Trash, or a volume's /Volumes/<name>/.Trashes/<uid>.
    /// `resolvedParent` is the item's folder with symlinks resolved (the helper passes the real one).
    public static func isInUsersTrash(path: String, resolvedParent: String, uid: UInt32, resolvedHomeTrash: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.unicodeScalars.contains("/") else { return false }
        if resolvedParent == resolvedHomeTrash { return true }
        // By code point: split(separator:) compares Characters, and "X/\u{301}" (a combining mark after the slash)
        // would stay one part, letting "/Volumes/X/\u{301}/.Trashes/501" pass for a volume's Trash.
        let parts = resolvedParent.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { Substring(String(String.UnicodeScalarView($0))) }
        // ["", "Volumes", "<name>", ".Trashes", "<uid>"]
        return parts.count == 5 && parts[0].isEmpty && parts[1] == "Volumes" && !parts[2].isEmpty && parts[2] != ".."
            && parts[3] == ".Trashes" && parts[4] == Substring(String(uid))
    }
}

/// Who may use the helper: administrators of this Mac only (the operator's decision). Standard users go through
/// macOS's own administrator prompt for each action instead, so the helper never gives them root.
extension PorpoiseHelperInfo {
    public static let administratorsOnly = "Porpoise's helper works only for administrators of this Mac."

    /// Whether user `uid` is in the "admin" group, as macOS's directory services see it (getgrouplist asks
    /// opendirectoryd, which includes groups nested in admin).
    public static func isAdministrator(_ uid: uid_t) -> Bool {
        guard let admin = getgrnam("admin")?.pointee.gr_gid, let pw = getpwuid(uid) else { return false }
        var capacity: Int32 = 64
        while capacity <= 1 << 16 {
            var list = [Int32](repeating: 0, count: Int(capacity))
            var count = capacity
            if getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &list, &count) != -1 {
                return list.prefix(Int(count)).contains(Int32(bitPattern: admin))
            }
            capacity *= 4
        }
        return false
    }

    /// Why the helper refuses the user `uid` who connected, or nil. `isAdministrator` is a seam for tests.
    public static func callerRefusal(_ uid: uid_t, isAdministrator: (uid_t) -> Bool = isAdministrator) -> String? {
        isAdministrator(uid) ? nil : administratorsOnly
    }
}
