import Foundation

/// What the privileged helper does with a request, apart from XPC and finding out who asked: checking it and running
/// the filesystem operation. Kept here so it can be tested in-process, without root or launchd.
public enum HelperRequests {
    private static let executionLock = NSLock()
    /// Why the helper won't run `arguments` (the tool first), or nil when it is one of `PorpoiseHelperInfo.allowedTools`
    /// in exactly a form Porpoise sends (`administratorCommands`, `renameCommands`, New Item, Properties): fixed
    /// options, then absolute paths. Where it may act, and with which approval, is `HelperPolicy`'s to say.
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
            // -h: a symlink's own mode, never its target's. Setuid, setgid and sticky bits need the protected approval.
            ok =
                a.count == 4 && a[0] == "-h" && a[1] == "--" && (1...4).contains(a[2].count) && a[2].allSatisfy { ("0"..."7").contains($0) }
                && writable(a[3])
        case "/bin/rm":
            ok = a.count == 3 && a[0] == "-rf" && a[1] == "--" && removable(a[2])
        case "/usr/bin/chflags":
            // chflags follows a link given as the operand: the flags would change on its target.
            ok =
                a.count == 3 && a[0] == "-R" && a[1] == "nouchg,noschg" && removable(a[2]) && !isSymlink(a[2])
                || a.count == 3 && a[0] == "-h" && settableFlag(a[1]) != nil && isPath(a[2])
        case "/usr/sbin/chown":
            // -h: a link itself. Numeric owner and group only: names would be looked up as root.
            ok = a.count == 4 && a[0] == "-h" && a[1] == "--" && isOwner(a[2]) && isPath(a[3])
        default:
            ok = false
        }
        return ok ? nil : "Porpoise's helper doesn't run \(tool) like this."
    }

    /// The single flags Properties sets or clears ("schg"/"noschg"…), as chflags names them.
    static let settableFlags: [String: UInt32] = [
        "uchg": UInt32(UF_IMMUTABLE), "uappnd": UInt32(UF_APPEND), "hidden": UInt32(UF_HIDDEN),
        "schg": UInt32(SF_IMMUTABLE), "sappnd": UInt32(SF_APPEND),
    ]

    static func settableFlag(_ name: String) -> (flag: UInt32, on: Bool)? {
        if let f = settableFlags[name] { return (f, true) }
        if name.hasPrefix("no"), let f = settableFlags[String(name.dropFirst(2))] { return (f, false) }
        return nil
    }

    /// "uid:gid", both numbers.
    static func isOwner(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.count <= 10 && $0.allSatisfy(\.isASCII) && UInt32($0) != nil }
    }

    /// An absolute path without "..": the helper never resolves a path relative to anything.
    static func isPath(_ p: String) -> Bool {
        p.hasPrefix("/") && p != "/" && !p.contains("\0") && !p.split(separator: "/").contains("..")
    }

    /// `p` with the folders leading to it resolved (a symlink on the way can't lead anywhere unseen).
    static func resolvedParent(_ p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return (ExistingPath.resolve(parent) ?? parent) + "/" + (p as NSString).lastPathComponent
    }

    /// The path itself is a symbolic link (not followed).
    static func isSymlink(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }

    /// A path that may be written to (created, replaced). Never an existing link: mv, cp and ln write into the folder
    /// a link points to, so only the parents' real paths could be checked, not where it lands.
    static func writable(_ p: String) -> Bool { isPath(p) && !isSymlink(p) }

    /// A path that may be moved away, removed or changed: anything but a volume's root, the top folders of the
    /// system ("/Applications", "/Users", "/private"…) and the system's fixed folders themselves. A link is removed
    /// as itself.
    static func removable(_ p: String) -> Bool {
        guard isPath(p) else { return false }
        let r = HelperPolicy.normalized(resolvedParent(p))
        let parts = r.split(separator: "/")
        if parts.count == 1 { return false }
        if parts.count == 2 && parts[0] == "Volumes" { return false }
        return !HelperPolicy.fixedFolders.contains(r)
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

    /// Decodes the allowlisted wire request and operates on validated descriptors. Never launches a tool. With no
    /// policy: no approval check (tests of the operations themselves).
    static func run(_ arguments: [String], policy: HelperPolicy? = nil, authorized: HelperTier = .standard) -> String? {
        executionLock.withLock {
            var operation = HelperFileOperations(policy: policy, authorized: authorized)
            return operation.run(arguments)
        }
    }

    /// What a batch came to: nil message when it all ran; `cancelled` when the person said no (nothing ran).
    public struct Reply: Equatable, Sendable {
        public var cancelled = false
        public var message: String?
        static let done = Reply()
        static func failed(_ m: String) -> Reply { Reply(message: m) }
    }

    static let notVerified = "Porpoise's request couldn't be verified. Try again."
    static let rightsChanged = "The helper's permissions were changed. Reinstall it in Settings › Advanced."

    /// One action: every request validated and classified first, then one approval for the strictest of them, with
    /// a prompt made from what will be done; then they run in order (lock flags cleared best effort), and the items
    /// the action moved into the person's Trash are handed to them (`handOver`, its destinations only).
    public static func perform(
        _ requests: [[String]], authorization: Data, handOver: [String], caller: uid_t, group: gid_t, home: String,
        authorizer: HelperAuthorizing, policy: HelperPolicy
    ) -> Reply {
        guard !requests.isEmpty else { return .done }
        var operations: [HelperOperation] = []
        for r in requests {
            do { operations.append(try HelperOperation(r)) } catch { return .failed(error.localizedDescription) }
        }
        let trash = ExistingPath.resolve(home + "/.Trash")
        var tier = HelperTier.standard
        var items: [HelperPrompt.Item] = []
        var shownPaths = Set<String>()
        for op in operations {
            let (t, reason) = policy.tier(of: op, facts: HelperPathFacts.read)
            if t == .never { return .failed(reason ?? HelperPolicy.sipMessage) }
            tier = max(tier, t)
            let paths = op.paths.map(\.path)
            // Lock flags cleared before a removal are part of it, not an item of their own.
            if case .unlock = op,
                operations.contains(where: {
                    if case .unlock = $0 { return false }; return $0.paths.first?.path == paths[0]
                })
            {
                continue
            }
            guard shownPaths.insert(paths.joined(separator: "\0")).inserted else { continue }
            let verb = HelperPrompt.verb(op, trash: trash)
            let shown = (verb == "move to the Trash" ? [paths[0]] : paths).map(HelperRequests.resolvedParent)
            items.append(HelperPrompt.Item(verb: verb, paths: shown, tier: t, reason: reason))
        }
        guard authorizer.rulesIntact() else { return .failed(rightsChanged) }
        switch authorizer.authorize(authorization, right: tier.right!, prompt: HelperPrompt.text(items, tier: tier)) {
        case .invalid: return .failed(notVerified)
        case .denied: return Reply(cancelled: true)
        case .granted: break
        }
        var moved = Set<String>()
        for (op, request) in zip(operations, requests) {
            let failure = run(request, policy: policy, authorized: tier)
            if case .unlock = op { continue }
            if let failure { return .failed(failure) }
            if case .move(_, let destination, _) = op { moved.insert(destination) }
        }
        for path in handOver where moved.contains(path) {
            _ = takeOwnership(path: path, uid: caller, gid: group, home: home)
        }
        return .done
    }
}
