import Darwin
import Foundation

/// How much approval a request needs before the helper runs it as root (W-245). The helper decides, from what it
/// will actually touch; the app only sends an empty authorization for it to use.
public enum HelperTier: Int, Comparable, Sendable {
    /// An action the person started on items that belong to the system or another volume: Touch ID or the password
    /// once, then 5 minutes without asking.
    case standard
    /// System configuration, what runs at startup, other people's files, ownership and setuid: asked every time.
    case protected
    /// What macOS itself protects (System Integrity Protection): never.
    case never

    public static func < (a: HelperTier, b: HelperTier) -> Bool { a.rawValue < b.rawValue }

    /// The right in the authorization database the person approves for this tier.
    public var right: String? {
        switch self {
        case .standard: return HelperRights.standard
        case .protected: return HelperRights.protected
        case .never: return nil
        }
    }
}

/// What a request does to one of its paths.
public enum HelperPathRole: Sendable { case read, write, remove, change }

/// One path of a request as the helper found it: its real path (the folders above resolved, in their on-disk case)
/// and, if it exists, the item itself (never a link's target).
public struct HelperPathFacts: Equatable, Sendable {
    public var path: String
    public var owner: uid_t?
    public var mode: mode_t?
    public var flags: UInt32?
    /// The item or its folder carries SF_RESTRICTED (System Integrity Protection).
    public var restricted = false
    /// Who owns the folder it's in (a write where nothing is yet lands in their folder).
    public var parentOwner: uid_t?

    public init(
        path: String, owner: uid_t? = nil, mode: mode_t? = nil, flags: UInt32? = nil, restricted: Bool = false, parentOwner: uid_t? = nil
    ) {
        self.path = path; self.owner = owner; self.mode = mode; self.flags = flags; self.restricted = restricted
        self.parentOwner = parentOwner
    }

    /// Read from the disk now: the parent resolved, the leaf by lstat, SF_RESTRICTED looked for on it and its folder.
    public static func read(_ p: String) -> HelperPathFacts {
        let full = HelperRequests.resolvedParent(p)
        var facts = HelperPathFacts(path: HelperPolicy.normalized(full))
        var st = stat()
        if lstat(full, &st) == 0 { facts.owner = st.st_uid; facts.mode = st.st_mode; facts.flags = st.st_flags }
        if lstat((full as NSString).deletingLastPathComponent, &st) == 0 { facts.parentOwner = st.st_uid }
        facts.restricted = isRestricted(full)
        return facts
    }

    /// The item at `path`, or the folder it's in, is SIP-protected. The flag isn't inherited: a restricted folder
    /// keeps its own entries (none added, removed or renamed), and an item in it without the flag of its own, such
    /// as /usr/local, can change.
    static func isRestricted(_ path: String) -> Bool {
        [path, (path as NSString).deletingLastPathComponent].contains { p in
            var st = stat()
            return lstat(p, &st) == 0 && st.st_flags & UInt32(SF_RESTRICTED) != 0
        }
    }
}

/// Where and how the helper may act, and with which approval. Pure: tests pass facts and folders of their own.
public struct HelperPolicy: Sendable {
    /// The user who asked.
    public var caller: uid_t
    /// The other people's home folders (real paths) and their names.
    public var otherHomes: [(path: String, name: String)]
    /// Folders whose contents decide what runs when the Mac starts.
    public var persistence = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools", "/Library/StartupItems"]
    /// The system's own configuration and secrets.
    public var configuration = ["/private/etc", "/private/var/db", "/private/var/root", "/Library/Security"]
    /// What holds private data outside people's homes: keychains, memory and swap, logs and audit trails. (Each
    /// person's temporary and cache folders, in /private/var/folders, are theirs: the owner rule covers them.)
    public var privateData = ["/Library/Keychains", "/private/var/vm", "/private/var/audit", "/private/var/log"]

    public init(caller: uid_t, otherHomes: [(path: String, name: String)]) {
        self.caller = caller
        self.otherHomes = otherHomes
    }

    /// For the user `caller`, with everyone else's home folders as directory services list them.
    public static func live(caller: uid_t) -> HelperPolicy { HelperPolicy(caller: caller, otherHomes: HomeDirectories.others(than: caller)) }

    /// Folders macOS keeps sealed (writes there need SIP off; the flag usually says so too).
    static let sealedSystem = ["/System", "/usr", "/bin", "/sbin"]
    /// The system's fixed folders, never moved, removed or replaced themselves (only what is in them).
    static let fixedFolders = Set(
        [
            "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools", "/Library/StartupItems", "/Library/Security",
            "/private/etc", "/private/var", "/private/var/db", "/private/var/root", "/private/tmp", "/Users/Shared", "/Volumes",
        ])

    static let containsReason = "contains the system's startup, configuration or home folders"
    static let startupReason = "changes what runs when your Mac starts"
    static let settingsReason = "changes system settings"
    public static let sipMessage = "macOS protects this item (System Integrity Protection): no app can change it."

    /// "/System/Volumes/Data/x" is "/x" (the data volume's firmlinked folders).
    public static func normalized(_ path: String) -> String {
        let data = "/System/Volumes/Data/"
        return path.hasPrefix(data) ? "/" + path.dropFirst(data.count) : path
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    /// The approval one path needs for `role`, and why when that's more than standard.
    public func tier(of facts: HelperPathFacts, role: HelperPathRole) -> (tier: HelperTier, reason: String?) {
        let p = facts.path
        let sealed = Self.sealedSystem.contains { Self.isInside(p, $0) } && !Self.isInside(p, "/usr/local")
        if role != .read && (facts.restricted || sealed) { return (.never, Self.sipMessage) }
        // A folder that holds the protected ones (/Library, /private/var…): whoever could re-own, re-mode or replace
        // it could swap what's inside for their own, with root's launch daemons among it.
        let guarded = persistence + configuration + privateData + otherHomes.map(\.path)
        if role != .read, guarded.contains(where: { $0.hasPrefix(p == "/" ? "/" : p + "/") }) { return (.never, Self.containsReason) }
        if let home = otherHomes.first(where: { Self.isInside(p, $0.path) }) {
            return (.protected, "belongs to \(home.name)")
        }
        if configuration.contains(where: { Self.isInside(p, $0) }) {
            return (.protected, role == .read ? "is the system's own configuration" : Self.settingsReason)
        }
        if privateData.contains(where: { Self.isInside(p, $0) }) { return (.protected, "contains private data") }
        if role != .read, persistence.contains(where: { Self.isInside(p, $0) }) {
            return (.protected, Self.startupReason)
        }
        // Another person's item (read, replaced, removed or changed), or for a new item their folder.
        let owner = role == .write ? (facts.owner ?? facts.parentOwner) : facts.owner
        if let owner, owner >= 501, owner != caller, owner != uid_t(bitPattern: -2) {
            return (.protected, "belongs to \(HomeDirectories.name(of: owner))")
        }
        if role != .read, let mode = facts.mode, mode & S_IFMT != S_IFDIR, mode & (S_ISUID | S_ISGID) != 0 {
            return (.protected, "is a setuid program")
        }
        return (.standard, nil)
    }

    /// The approval a whole operation needs: its paths', and what it changes.
    func tier(of op: HelperOperation, facts: (String) -> HelperPathFacts) -> (tier: HelperTier, reason: String?) {
        var worst: (tier: HelperTier, reason: String?) = (.standard, nil)
        func take(_ t: (tier: HelperTier, reason: String?)) { if t.tier > worst.tier { worst = t } }
        for (path, role) in op.paths { take(tier(of: facts(path), role: role)) }
        switch op {
        case .chmod(_, let mode) where mode & 0o7000 != 0:
            take((.protected, mode & 0o6000 != 0 ? "sets setuid" : "sets the sticky bit"))
        case .chown(_, let uid, let gid) where uid != caller || gid == 0:
            take((.protected, uid == 0 ? "makes root the owner" : "changes who owns it"))
        case .setFlag(_, let flag, true) where flag & UInt32(SF_IMMUTABLE | SF_APPEND) != 0:
            take((.protected, "sets a system lock"))
        default: break
        }
        return worst
    }
}

/// Everyone's home folders, as directory services list them (a home can be anywhere: another volume, /var for a
/// service account, a network home).
public enum HomeDirectories {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, homes: [(uid: uid_t, path: String, name: String)])?

    /// The homes of people other than `caller` (uid 501 and up), real paths.
    public static func others(than caller: uid_t) -> [(path: String, name: String)] {
        all().filter { $0.uid != caller }.map { ($0.path, $0.name) }
    }

    /// A person's short name, or their number.
    static func name(of uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "user \(uid)" }
        return String(cString: pw.pointee.pw_name)
    }

    private static func all() -> [(uid: uid_t, path: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, Date().timeIntervalSince(c.at) < 60 { return c.homes }
        var homes: [(uid: uid_t, path: String, name: String)] = []
        setpwent()
        while let pw = getpwent() {
            let uid = pw.pointee.pw_uid
            guard uid >= 501, uid != uid_t(bitPattern: -2) else { continue }
            let dir = String(cString: pw.pointee.pw_dir)
            guard dir.hasPrefix("/"), dir != "/", dir != "/var/empty", let real = ExistingPath.resolve(dir) else { continue }
            homes.append((uid, HelperPolicy.normalized(real), String(cString: pw.pointee.pw_name)))
        }
        endpwent()
        cached = (Date(), homes)
        return homes
    }
}
