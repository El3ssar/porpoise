import Foundation

/// What the privileged helper does with a request, apart from XPC and finding out who asked: checking it and running
/// the tool. Kept here so it can be tested in-process, without root or launchd.
public enum HelperRequests {
    /// Why the helper won't run `arguments` (the tool first), or nil when it is one of `PorpoiseHelperInfo.allowedTools`
    /// in exactly a form Porpoise sends (`administratorCommands`, `renameCommands`, New Item, Properties): fixed
    /// options, then absolute paths. A process that got into Porpoise can't make it run anything else as root:
    /// no other flags, no `chmod` to setuid, nothing written into the system's own folders.
    public static func refusal(_ arguments: [String]) -> String? {
        guard let tool = arguments.first, PorpoiseHelperInfo.allowedTools.contains(tool) else {
            return "Porpoise's helper doesn't run \(arguments.first ?? "nothing")."
        }
        let a = Array(arguments.dropFirst())
        let ok: Bool
        switch tool {
        case "/bin/mv":
            ok =
                (a.count == 3 && a[0] == "--" || a.count == 4 && a[0] == "-n" && a[1] == "--")
                && removable(a[a.count - 2]) && writable(a[a.count - 1])
        case "/bin/cp":
            ok =
                (a.count == 3 && a[0] == "--" || a.count == 4 && a[0] == "-pR" && a[1] == "--")
                && isPath(a[a.count - 2]) && writable(a[a.count - 1])
        case "/bin/ln":
            // The link's target is only text stored in the link: any, but not empty.
            ok = a.count == 4 && a[0] == "-s" && a[1] == "--" && !a[2].isEmpty && !a[2].contains("\0") && writable(a[3])
        case "/bin/mkdir":
            ok = a.count == 2 && a[0] == "--" && writable(a[1])
        case "/bin/chmod":
            // -h: a symlink's own mode, never its target's. No setuid, setgid or sticky bits.
            ok =
                a.count == 4 && a[0] == "-h" && a[1] == "--" && a[2].count <= 4 && a[2].allSatisfy { ("0"..."7").contains($0) }
                && (Int(a[2], radix: 8) ?? 0o7000) & 0o7000 == 0 && writable(a[3])
        case "/bin/rm":
            ok = a.count == 3 && a[0] == "-rf" && a[1] == "--" && removable(a[2])
        case "/usr/bin/chflags":
            // chflags follows a link given as the operand: the flags would change on its target.
            ok = a.count == 3 && a[0] == "-R" && a[1] == "nouchg,noschg" && removable(a[2]) && !isSymlink(a[2])
        default:
            ok = false
        }
        return ok ? nil : "Porpoise's helper doesn't run \(tool) like this."
    }

    /// Where nothing may be created, replaced or have its permissions changed (as their real paths, lower case:
    /// volumes are usually case-insensitive).
    static let protectedFolders = [
        "/system", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/root", "/library/launchdaemons", "/library/launchagents",
        "/library/privilegedhelpertools", "/library/startupitems", "/library/security", "/private/var/db",
    ]

    /// An absolute path without "..": the helper never resolves a path relative to anything.
    static func isPath(_ p: String) -> Bool {
        p.hasPrefix("/") && p != "/" && !p.contains("\0") && !p.split(separator: "/").contains("..")
    }

    /// `p` with the folders leading to it resolved (a symlink on the way can't lead into a protected folder unseen).
    static func resolvedParent(_ p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return (ExistingPath.resolve(parent) ?? parent) + "/" + (p as NSString).lastPathComponent
    }

    static func isProtected(_ p: String) -> Bool {
        let r = resolvedParent(p).lowercased()
        if r.hasPrefix("/usr/local/") { return false }  // the administrator's own tools
        return protectedFolders.contains { r == $0 || r.hasPrefix($0 + "/") }
    }

    /// The path itself is a symbolic link (not followed).
    static func isSymlink(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }

    /// A path that may be written to (created, replaced, re-moded). Never an existing link: mv, cp and ln write
    /// into the folder a link points to, so only the parents' real paths could be checked, not where it lands.
    static func writable(_ p: String) -> Bool { isPath(p) && !isProtected(p) && !isSymlink(p) }

    /// Where nothing may be removed either: the system's own configuration and secrets. (What apps install in
    /// the other protected folders, such as a launch daemon's plist, may be moved away: that is how they're uninstalled.)
    static let sealedFolders = ["/private/etc", "/private/var/root", "/private/var/db", "/library/security"]

    /// A path that may be moved away or removed: anything but a volume's root, the top folders of the system, the
    /// protected folders themselves and anything in the sealed ones. A link is removed as itself.
    static func removable(_ p: String) -> Bool {
        guard isPath(p) else { return false }
        let r = resolvedParent(p).lowercased()
        let parts = r.split(separator: "/")
        if parts.count == 1 { return false }  // "/Applications", "/Users", "/private"…
        if parts.count == 2 && parts[0] == "volumes" { return false }
        if protectedFolders.contains(r) { return false }
        return !(["/system", "/usr", "/bin", "/sbin"] + sealedFolders).contains { r == $0 || r.hasPrefix($0 + "/") }
    }

    static let ownershipRefused = "Only items in your own Trash can be handed over."

    /// The real path of `path` if it sits directly in user `uid`'s Trash (home folder `home`) and isn't a symlink
    /// (chown would change its target), else nil.
    public static func ownershipTarget(path: String, uid: UInt32, home: String) -> String? {
        let item = URL(fileURLWithPath: path)
        let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard trashIsAFolder(home) else { return nil }
        let homeTrash = URL(fileURLWithPath: home).appendingPathComponent(".Trash").resolvingSymlinksInPath().path
        // The item itself, named exactly: "link/" or "link//" would make lstat (and resolving) follow a symlink.
        let target = parent + "/" + (path as NSString).lastPathComponent
        var st = stat()
        guard PorpoiseHelperInfo.isInUsersTrash(path: path, resolvedParent: parent, uid: uid, resolvedHomeTrash: homeTrash),
            lstat(target, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK
        else { return nil }
        return target
    }

    /// Makes user `uid` (group `gid`) the owner of an item in their Trash and of everything in it, as root would with
    /// `chown -R -P`, but without trusting any path between the check and the change: the user owns the Trash and can
    /// swap what's in it meanwhile. Everything is opened (never following a symlink) and changed through its file
    /// descriptor; the Trash folder is checked again as opened. Files with more than one name are left alone: the other
    /// name could be anywhere on the volume (`ln /etc/sudoers ~/.Trash/x`). Nil on success, else what went wrong.
    public static func takeOwnership(path: String, uid: UInt32, gid: UInt32, home: String) -> String? {
        guard let target = ownershipTarget(path: path, uid: uid, home: home) else { return ownershipRefused }
        let name = (target as NSString).lastPathComponent
        let dir = open((target as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return "Could not open the Trash: \(String(cString: strerror(errno)))." }
        defer { close(dir) }
        // What was opened, not what the path named a moment ago: a folder on the way, swapped for a symlink, would
        // have led somewhere else. realpath, unlike resolvingSymlinksInPath, keeps "/private" as F_GETPATH does.
        let homeTrash = ExistingPath.resolve(home + "/.Trash") ?? home + "/.Trash"
        guard trashIsAFolder(home), let opened = pathOf(dir),
            PorpoiseHelperInfo.isInUsersTrash(path: opened + "/" + name, resolvedParent: opened, uid: uid, resolvedHomeTrash: homeTrash)
        else { return ownershipRefused }
        var walk = OwnershipWalk(uid: uid, gid: gid)
        walk.change(name, in: dir, isTop: true)
        return walk.problem
    }

    /// The home folder may be reached through a link, but its Trash must be a folder: a `.Trash` symlinked elsewhere
    /// (/private/etc) would make "the user's Trash" any folder they like.
    static func trashIsAFolder(_ home: String) -> Bool {
        var st = stat()
        return lstat((ExistingPath.resolve(home) ?? home) + "/.Trash", &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private static func pathOf(_ fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return fcntl(fd, F_GETPATH, &buf) == 0 ? String(cString: buf) : nil
    }

    private struct OwnershipWalk {
        let uid: uid_t, gid: gid_t
        var linked = 0
        var errors: [String] = []

        var problem: String? {
            var parts = errors.prefix(3).map { $0 }
            if linked > 0 { parts.append("\(linked) file(s) with more than one name were left as they are.") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        mutating func change(_ name: String, in dir: Int32, isTop: Bool) {
            // O_SYMLINK: a symlink is opened itself, never followed. O_NONBLOCK: a FIFO doesn't wait for a writer.
            let fd = openat(dir, name, O_RDONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return fail(name) }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return fail(name) }
            let type = st.st_mode & S_IFMT
            if isTop && type == S_IFLNK { errors.append(HelperRequests.ownershipRefused); return }
            if type != S_IFDIR && st.st_nlink > 1 { linked += 1; return }
            guard fchown(fd, uid, gid) == 0 else { return fail(name) }
            guard type == S_IFDIR else { return }
            for child in Self.names(in: fd) { change(child, in: fd, isTop: false) }
        }

        private mutating func fail(_ name: String) { errors.append("“\(name)”: \(String(cString: strerror(errno))).") }

        /// The folder's entries, read through a duplicate of its descriptor (closedir closes that one).
        private static func names(in fd: Int32) -> [String] {
            let copy = dup(fd)
            guard copy >= 0, let d = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                return []
            }
            defer { closedir(d) }
            var out: [String] = []
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name != "." && name != ".." { out.append(name) }
            }
            return out
        }
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
