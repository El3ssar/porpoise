import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseHelperKit

/// The root helper hands items over only inside the asking user's own Trash.
@Suite struct HelperPolicyTests {
    let trash = "/Users/me/.Trash"

    @Test func itemsInTheHomeTrash() {
        #expect(PorpoiseHelperInfo.isInUsersTrash(path: "/Users/me/.Trash/Game.app", resolvedParent: trash, uid: 501, resolvedHomeTrash: trash))
    }

    @Test func itemsInAVolumesTrashForThatUser() {
        #expect(
            PorpoiseHelperInfo.isInUsersTrash(
                path: "/Volumes/Disk/.Trashes/501/x", resolvedParent: "/Volumes/Disk/.Trashes/501", uid: 501, resolvedHomeTrash: trash))
        #expect(
            !PorpoiseHelperInfo.isInUsersTrash(
                path: "/Volumes/Disk/.Trashes/502/x", resolvedParent: "/Volumes/Disk/.Trashes/502", uid: 501, resolvedHomeTrash: trash))
    }

    @Test func nothingElse() {
        for (path, parent) in [
            ("/etc/sudoers", "/etc"), ("/Users/me/.Trash/a/b", "/Users/me/.Trash/a"), ("/Users/other/.Trash/x", "/Users/other/.Trash"),
            ("/Users/me/.Trash/..", trash), ("/Volumes/Disk/.Trashes/501/../x", "/Volumes/Disk/.Trashes"),
            ("/Volumes/../.Trashes/501/x", "/Volumes/../.Trashes/501"), ("/Library/.Trashes/501/x", "/Library/.Trashes/501"),
        ] {
            #expect(!PorpoiseHelperInfo.isInUsersTrash(path: path, resolvedParent: parent, uid: 501, resolvedHomeTrash: trash), "\(path)")
        }
    }
}

/// The helper is for administrators of this Mac only (the operator's decision).
@Suite struct HelperCallerTests {
    @Test func onlyAdministratorsAreServed() {
        var asked: [uid_t] = []
        let refusal = PorpoiseHelperInfo.callerRefusal(501) {
            asked.append($0); return false
        }
        #expect(refusal == PorpoiseHelperInfo.administratorsOnly)
        #expect(asked == [501])
        #expect(PorpoiseHelperInfo.callerRefusal(502) { _ in true } == nil)
    }

    @Test func membershipIsWhatTheSystemSays() throws {
        // `id -Gn` asks the same directory services.
        let r = try runTool("/usr/bin/id", ["-Gn"])
        let names = String(decoding: r.out, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        #expect(PorpoiseHelperInfo.isAdministrator(getuid()) == names.contains("admin"))
        #expect(PorpoiseHelperInfo.isAdministrator(0))  // root is in admin
        #expect(!PorpoiseHelperInfo.isAdministrator(uid_t(bitPattern: -2)))  // nobody
        #expect(!PorpoiseHelperInfo.isAdministrator(987_654))  // no such user
        #expect(PorpoiseHelperInfo.callerRefusal(uid_t(bitPattern: -2)) == PorpoiseHelperInfo.administratorsOnly)
    }
}

/// What the helper runs, decided in-process: only the listed tools, exactly; ownership only for real items directly in
/// the user's own Trash. The tools themselves run here as the current user, on throwaway files.
@Suite struct HelperRequestTests {
    let fm = FileManager.default

    // MARK: Allowlist

    @Test func allowsExactlyTheListedTools() {
        // Each tool in a form Porpoise sends.
        let sent: [[String]] = [
            ["/bin/mv", "--", "/Users/me/a", "/Users/me/.Trash/a"], ["/bin/mv", "-n", "--", "/Applications/A.app", "/Applications/B.app"],
            ["/bin/cp", "-pR", "--", "/Users/me/a", "/Library/Fonts/a"], ["/bin/cp", "--", "/tmp/x", "/Applications/new.txt"],
            ["/bin/ln", "-s", "--", "../relative target", "/usr/local/bin/tool"], ["/bin/mkdir", "--", "/Library/Application Support/X"],
            ["/bin/chmod", "-h", "--", "755", "/Applications/A.app"], ["/bin/rm", "-rf", "--", "/Applications/A.app"],
            ["/usr/bin/chflags", "-R", "nouchg,noschg", "/Library/Old/thing"],
        ]
        for args in sent { #expect(HelperRequests.refusal(args) == nil, "\(args)") }
        #expect(Set(sent.map { $0[0] }) == PorpoiseHelperInfo.allowedTools)
        #expect(PorpoiseHelperInfo.allowedTools.allSatisfy { $0.hasPrefix("/") })
        #expect(
            !PorpoiseHelperInfo.allowedTools.contains { $0.hasSuffix("/sh") || $0.hasSuffix("bash") || $0.hasSuffix("zsh") || $0.hasSuffix("chown") })
    }

    @Test func refusesEverythingElse() {
        let bad: [[String]] = [
            [], [""], ["mv", "a", "b"], ["rm"], ["/bin/sh", "-c", "id"], ["/bin/bash"], ["/usr/sbin/chown", "0:0", "/x"],
            ["/bin/../bin/rm", "x"], ["//bin/rm", "x"], ["/bin//rm", "x"], ["/bin/rm/", "x"], ["/bin/./rm", "x"], [" /bin/rm", "x"],
            ["/bin/rm ", "x"], ["/BIN/RM", "x"], ["/bin/rm\0", "x"], ["/bin/rm -rf /"], ["/bin/mv;id"], ["/usr/local/bin/mv"],
            ["/sbin/mv"], ["/bin/cp\n"], ["x", "/bin/rm"],
        ]
        for args in bad {
            let r = HelperRequests.refusal(args)
            #expect(r != nil, "\(args)")
            #expect(r?.hasPrefix("Porpoise's helper doesn't run") == true)
        }
        #expect(HelperRequests.refusal([]) == "Porpoise's helper doesn't run nothing.")
    }

    /// The tools only in the shapes Porpoise uses: no other flags, no setuid, nothing written into the system's
    /// own folders, no volume or system root removed, no relative paths or "..".
    @Test func refusesOtherArgumentsOfTheAllowedTools() throws {
        let s = try Scratch()
        try s.symlink("toEtc", to: "/private/etc")
        let bad: [[String]] = [
            ["/bin/rm", "-rf", "/"], ["/bin/rm", "-rf", "--", "/"], ["/bin/rm", "-rf", "--", "/Users"], ["/bin/rm", "-rf", "--", "/Volumes/Disk"],
            ["/bin/rm", "-rf", "--", "/System/Library"], ["/bin/rm", "-rf", "--", "/usr/bin/true"], ["/bin/rm", "-f", "--", "/x/y"],
            ["/bin/rm", "-rf", "--", "relative/x"], ["/bin/rm", "-rf", "--", "/x/../etc/y"], ["/bin/rm", "-rf", "--", "/a/b", "/c/d"],
            ["/bin/cp", "--", "/tmp/x", "/etc/sudoers"], ["/bin/cp", "--", "/tmp/x", "/private/etc/sudoers"],
            ["/bin/cp", "-pR", "--", "/tmp/x", "/Library/LaunchDaemons/evil.plist"], ["/bin/cp", "-f", "--", "/tmp/x", "/Users/me/y"],
            ["/bin/mv", "--", "/tmp/x", "/LIBRARY/launchdaemons/evil.plist"], ["/bin/mv", "-f", "/a/b", "/c/d"],
            ["/bin/mv", "--", "/tmp/x", s.path("toEtc").path + "/sudoers"],  // a link on the way into /private/etc
            ["/bin/ln", "-s", "--", "/tmp/evil", "/Library/LaunchAgents/x.plist"], ["/bin/ln", "--", "/a", "/b/c"],
            ["/bin/ln", "-s", "--", "", "/b/c"],
            ["/bin/chmod", "4755", "/Applications/A.app"], ["/bin/chmod", "--", "755", "/Applications/A.app"],
            ["/bin/chmod", "-h", "--", "4755", "/Applications/A.app"], ["/bin/chmod", "-h", "--", "2755", "/x/y"],
            ["/bin/chmod", "-h", "--", "u+s", "/x/y"], ["/bin/chmod", "-h", "--", "666", "/private/etc/periodic/daily/x"],
            ["/bin/mkdir", "-p", "/x/y"], ["/bin/mkdir", "--", "/usr/libexec/x"], ["/usr/bin/chflags", "uchg", "/x/y"],
            ["/usr/bin/chflags", "-R", "nouchg,noschg", "/"],
        ]
        for args in bad {
            #expect(HelperRequests.refusal(args)?.hasSuffix("like this.") == true, "\(args)")
        }
    }

    /// A destination that is itself a link: the tools would write into the folder it points to, which the check
    /// can't see. Refused for every tool that writes, whatever the link points to.
    @Test func refusesALinkAsTheDestination() throws {
        let s = try Scratch()
        for (i, folder) in (HelperRequests.protectedFolders + ["/Users/Shared"]).enumerated() {
            let link = try s.symlink("link\(i)", to: folder).path
            for args in [
                ["/bin/mv", "--", "/tmp/x", link], ["/bin/mv", "-n", "--", "/tmp/x", link], ["/bin/cp", "--", "/tmp/x", link],
                ["/bin/cp", "-pR", "--", "/tmp/x", link], ["/bin/ln", "-s", "--", "/tmp/evil", link], ["/bin/mkdir", "--", link],
                ["/bin/chmod", "-h", "--", "644", link],
            ] {
                #expect(HelperRequests.refusal(args)?.hasSuffix("like this.") == true, "\(args) → \(folder)")
            }
            // chflags follows its operand; rm and mv remove or move the link itself.
            #expect(HelperRequests.refusal(["/usr/bin/chflags", "-R", "nouchg,noschg", link]) != nil, "\(folder)")
            #expect(HelperRequests.refusal(["/bin/rm", "-rf", "--", link]) == nil, "\(folder)")
            #expect(HelperRequests.refusal(["/bin/mv", "--", link, s.path("moved\(i)").path]) == nil, "\(folder)")
        }
        // The same destinations as real paths that don't exist yet are still fine.
        #expect(HelperRequests.refusal(["/bin/mv", "--", "/tmp/x", s.path("new").path]) == nil)
    }

    /// Removing: never a protected folder itself or anything in the system's configuration and secrets; what apps
    /// install in the other protected folders may go (that's how they're uninstalled).
    @Test func removesNothingOfTheSystemsOwn() {
        for p in HelperRequests.protectedFolders + ["/private/etc/hosts", "/private/var/db/sudo", "/Library/Security/x", "/private/var/root/.ssh"] {
            #expect(HelperRequests.refusal(["/bin/rm", "-rf", "--", p]) != nil, "\(p)")
            #expect(HelperRequests.refusal(["/bin/mv", "--", p, "/Users/me/.Trash/x"]) != nil, "\(p)")
            #expect(HelperRequests.refusal(["/usr/bin/chflags", "-R", "nouchg,noschg", p]) != nil, "\(p)")
        }
        for p in [
            "/Library/LaunchDaemons/com.vendor.helper.plist", "/Library/LaunchAgents/com.vendor.agent.plist",
            "/Library/PrivilegedHelperTools/com.vendor.helper",
        ] {
            #expect(HelperRequests.refusal(["/bin/mv", "--", p, "/Users/me/.Trash/x"]) == nil, "\(p)")
            #expect(HelperRequests.refusal(["/bin/rm", "-rf", "--", p]) == nil, "\(p)")
        }
    }

    // MARK: Running the tools (as the current user, in a scratch folder)

    /// Names a shell would split, expand or run: each must stay one argument.
    static let hostileNames = [
        "a b", "$(touch pwned)", "`touch pwned`", "x;touch pwned", "-rf", "--", "*", "q\"uote'", "new\nline",
        "|touch pwned", "&& touch pwned", "~", "$HOME", "é ü 日本", ">out", "\\back",
    ]

    @Test func movesCopiesAndLinksHostileNamesAsSingleArguments() throws {
        let s = try Scratch()
        for (i, name) in Self.hostileNames.enumerated() {
            let src = try s.file("src/\(i)/\(name)", "data \(i)")
            try s.folder("dst/\(i)")
            let dst = s.path("dst/\(i)")
            // "--" ends options: names starting with "-" are not taken as flags.
            #expect(HelperRequests.run(["/bin/cp", "-pR", "--", src.path, dst.appendingPathComponent("copy").path]) == nil, "\(name)")
            #expect(HelperRequests.run(["/bin/ln", "-s", "--", src.path, dst.appendingPathComponent("link").path]) == nil, "\(name)")
            #expect(HelperRequests.run(["/bin/mv", "--", src.path, dst.appendingPathComponent(name).path]) == nil, "\(name)")
            #expect(s.read("dst/\(i)/\(name)") == "data \(i)")
            #expect(s.read("dst/\(i)/copy") == "data \(i)")
            #expect(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("link").path) == src.path)
        }
        // Nothing a shell would have run.
        #expect(!fm.fileExists(atPath: s.path("pwned").path))
        #expect(!fm.fileExists(atPath: fm.currentDirectoryPath + "/pwned"))
        #expect(!fm.fileExists(atPath: s.path("dst/0/out").path))
    }

    @Test func mkdirChmodChflagsAndRm() throws {
        let s = try Scratch()
        let dir = s.path("made/$(id)/deep")
        try s.folder("made/$(id)")
        #expect(HelperRequests.run(["/bin/mkdir", "--", dir.path]) == nil)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        let f = try s.file("made/f;rm -rf ~", "x")
        #expect(HelperRequests.run(["/bin/chmod", "-h", "--", "600", f.path]) == nil)
        #expect((try fm.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(chflags(f.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect((try fm.attributesOfItem(atPath: f.path)[.immutable] as? Bool) == true)
        #expect(HelperRequests.run(["/bin/rm", "-rf", "--", f.path]) != nil)  // locked: rm fails and says why
        #expect(HelperRequests.run(["/usr/bin/chflags", "-R", "nouchg,noschg", f.path]) == nil)
        #expect(HelperRequests.run(["/bin/rm", "-rf", "--", s.path("made").path]) == nil)
        #expect(s.listing() == [])
    }

    @Test func failuresReportTheToolsMessage() throws {
        let s = try Scratch()
        let r = HelperRequests.run(["/bin/mv", "--", s.path("missing").path, s.path("x").path])
        #expect(r?.contains("No such file or directory") == true)
        #expect(r?.hasSuffix("\n") == false)
        // A tool that fails silently still reports something.
        #expect(HelperRequests.run(["/usr/bin/false"]) == "Porpoise's helper doesn't run /usr/bin/false.")
        #expect(HelperRequests.run(["/nonexistent/tool"]) != nil)
        #expect(HelperRequests.run([]) == "Porpoise's helper doesn't run nothing.")
    }

    // MARK: Taking ownership of trashed items

    /// A home folder with a Trash, and things outside it.
    private func home() throws -> (Scratch, home: String, trash: URL) {
        let s = try Scratch()
        let trash = try s.folder("home/.Trash")
        try s.file("outside/secret", "s")
        return (s, s.path("home").path, trash)
    }

    @Test func ownershipOfItemsInTheHomeTrash() throws {
        let (s, home, trash) = try home()
        try s.file("home/.Trash/Game.app/Contents/x")
        try s.file("home/.Trash/a b; $(id)")
        let app = HelperRequests.ownershipTarget(path: trash.appendingPathComponent("Game.app").path, uid: 501, home: home)
        #expect(app == trash.appendingPathComponent("Game.app").path)
        let odd = HelperRequests.ownershipTarget(path: trash.appendingPathComponent("a b; $(id)").path, uid: 7, home: home)
        #expect(odd == trash.appendingPathComponent("a b; $(id)").path)
    }

    @Test func noOwnershipOutsideTheTrashOrForMissingItems() throws {
        let (s, home, trash) = try home()
        try s.file("home/.Trash/dir/inner", "i")
        try s.file("home/Documents/doc", "d")
        for p in [
            s.path("outside/secret").path, s.path("home/Documents/doc").path, trash.appendingPathComponent("dir/inner").path,
            trash.appendingPathComponent("missing").path, trash.path, trash.path + "/.", trash.path + "/..",
            trash.appendingPathComponent("../Documents/doc").path, "/etc/sudoers", "",
        ] {
            #expect(HelperRequests.ownershipTarget(path: p, uid: getuid(), home: home) == nil, "\(p)")
        }
    }

    @Test func noOwnershipThroughSymlinks() throws {
        let (s, home, trash) = try home()
        // The item itself a symlink (chown would change its target), to a file or a folder outside.
        try s.symlink("home/.Trash/toFile", to: s.path("outside/secret").path)
        try s.symlink("home/.Trash/toDir", to: s.path("outside").path)
        // A folder that only looks like the Trash: a symlink to a folder elsewhere.
        try s.folder("elsewhere")
        try s.file("elsewhere/item", "e")
        try s.symlink("home/FakeTrash", to: s.path("elsewhere").path)
        for p in [
            trash.appendingPathComponent("toFile").path, trash.appendingPathComponent("toDir").path,
            // A trailing slash or "/." makes lstat follow the link: still refused.
            trash.appendingPathComponent("toDir").path + "/", trash.appendingPathComponent("toDir").path + "//",
            trash.appendingPathComponent("toDir").path + "/.", trash.appendingPathComponent("toDir/secret").path,
            s.path("home/FakeTrash/item").path,
        ] {
            #expect(HelperRequests.ownershipTarget(path: p, uid: getuid(), home: home) == nil, "\(p)")
        }
    }

    /// A `.Trash` that is a symlink (to /private/etc, say) is not the user's Trash.
    @Test func noOwnershipThroughASymlinkedTrash() throws {
        let s = try Scratch()
        try s.file("outside/secret", "s")
        try s.folder("home")
        try s.symlink("home/.Trash", to: s.path("outside").path)
        let home = s.path("home").path
        #expect(HelperRequests.ownershipTarget(path: s.path("home/.Trash/secret").path, uid: getuid(), home: home) == nil)
        #expect(HelperRequests.takeOwnership(path: s.path("home/.Trash/secret").path, uid: getuid(), gid: getgid(), home: home) != nil)
    }

    @Test func aTrashReachedThroughASymlinkedHomeStillCounts() throws {
        let s = try Scratch()
        try s.file("real/.Trash/item", "x")
        try s.symlink("linkedHome", to: s.path("real").path)
        let target = HelperRequests.ownershipTarget(path: s.path("linkedHome/.Trash/item").path, uid: 501, home: s.path("linkedHome").path)
        // The real item, never a path through a link.
        #expect(target == s.path("real/.Trash/item").path)
    }

    // MARK: Handing over, for real (to the current user, with another of its groups: no root needed)

    /// A group the current user is in besides `except`, or nil.
    static func otherGroup(than except: gid_t) -> gid_t? {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let n = getgroups(Int32(groups.count), &groups)
        return n > 0 ? groups.prefix(Int(n)).first { $0 != except } : nil
    }

    private func group(_ url: URL) -> gid_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_gid
    }

    @Test func handsOverAFolderAndEverythingInIt() throws {
        let (s, home, trash) = try home()
        let inner = try s.file("home/.Trash/Game.app/Contents/MacOS/game", "g")
        let before = group(inner)
        let other = try #require(Self.otherGroup(than: before), "needs a user in two groups")
        #expect(HelperRequests.takeOwnership(path: trash.appendingPathComponent("Game.app").path, uid: getuid(), gid: other, home: home) == nil)
        for u in [trash.appendingPathComponent("Game.app"), s.path("home/.Trash/Game.app/Contents/MacOS"), inner] {
            #expect(group(u) == other, "\(u.path)")
        }
    }

    /// A hard link planted in the Trash is another name for a file anywhere on the volume (`ln /etc/sudoers
    /// ~/.Trash/x`): chown -R changed that file. Symlinks inside are changed themselves, never their targets.
    @Test func leavesHardLinksAndSymlinkTargetsAlone() throws {
        let (s, home, trash) = try home()
        let secret = s.path("outside/secret")
        let before = group(secret)
        let other = try #require(Self.otherGroup(than: before), "needs a user in two groups")
        let plain = try s.file("home/.Trash/dir/plain", "p")
        try FileManager.default.linkItem(at: secret, to: trash.appendingPathComponent("dir/hard"))
        let soft = try s.symlink("home/.Trash/dir/soft", to: secret.path)
        let problem = HelperRequests.takeOwnership(path: trash.appendingPathComponent("dir").path, uid: getuid(), gid: other, home: home)
        #expect(problem?.contains("more than one name") == true)
        #expect(group(plain) == other && group(soft) == other && group(trash.appendingPathComponent("dir")) == other)
        #expect(group(secret) == before)
        // Directly in the Trash, too.
        try FileManager.default.linkItem(at: secret, to: trash.appendingPathComponent("top"))
        #expect(HelperRequests.takeOwnership(path: trash.appendingPathComponent("top").path, uid: getuid(), gid: other, home: home) != nil)
        #expect(group(secret) == before)
    }

    @Test func refusesWhatOwnershipTargetRefuses() throws {
        let (s, home, trash) = try home()
        try s.symlink("home/.Trash/toFile", to: s.path("outside/secret").path)
        for p in [trash.appendingPathComponent("toFile").path, s.path("outside/secret").path, trash.appendingPathComponent("missing").path] {
            #expect(HelperRequests.takeOwnership(path: p, uid: getuid(), gid: getgid(), home: home) == HelperRequests.ownershipRefused, "\(p)")
        }
    }
}
