import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

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

/// What the helper runs, decided in-process: only the listed tools, exactly; ownership only for real items directly in
/// the user's own Trash. The tools themselves run here as the current user, on throwaway files.
@Suite struct HelperRequestTests {
    let fm = FileManager.default

    // MARK: Allowlist

    @Test func allowsExactlyTheListedTools() {
        for tool in PorpoiseHelperInfo.allowedTools { #expect(HelperRequests.refusal([tool, "x"]) == nil, "\(tool)") }
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
            #expect(HelperRequests.run(["/bin/cp", "-R", "--", src.path, dst.appendingPathComponent("copy").path]) == nil, "\(name)")
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
        #expect(HelperRequests.run(["/bin/mkdir", "-p", dir.path]) == nil)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        let f = try s.file("made/f;rm -rf ~", "x")
        #expect(HelperRequests.run(["/bin/chmod", "600", f.path]) == nil)
        #expect((try fm.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(HelperRequests.run(["/usr/bin/chflags", "uchg", f.path]) == nil)
        #expect((try fm.attributesOfItem(atPath: f.path)[.immutable] as? Bool) == true)
        #expect(HelperRequests.run(["/bin/rm", "-f", f.path]) != nil)  // locked: rm fails and says why
        #expect(HelperRequests.run(["/usr/bin/chflags", "nouchg", f.path]) == nil)
        #expect(HelperRequests.run(["/bin/rm", "-rf", s.path("made").path]) == nil)
        #expect(s.listing() == [])
    }

    @Test func failuresReportTheToolsMessage() throws {
        let s = try Scratch()
        let r = HelperRequests.run(["/bin/mv", s.path("missing").path, s.path("x").path])
        #expect(r?.contains("No such file or directory") == true)
        #expect(r?.hasSuffix("\n") == false)
        // A tool that fails silently still reports something.
        #expect(HelperRequests.run(["/usr/bin/false"]) == "/usr/bin/false failed.")
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
        let cmd = HelperRequests.ownershipCommand(path: trash.appendingPathComponent("Game.app").path, uid: 501, gid: 20, home: home)
        #expect(cmd == ["/usr/sbin/chown", "-R", "-P", "501:20", trash.appendingPathComponent("Game.app").path])
        let odd = HelperRequests.ownershipCommand(path: trash.appendingPathComponent("a b; $(id)").path, uid: 7, gid: 8, home: home)
        #expect(odd?.last == trash.appendingPathComponent("a b; $(id)").path)
        #expect(odd?.count == 5)
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
            #expect(HelperRequests.ownershipCommand(path: p, uid: getuid(), gid: getgid(), home: home) == nil, "\(p)")
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
            #expect(HelperRequests.ownershipCommand(path: p, uid: getuid(), gid: getgid(), home: home) == nil, "\(p)")
        }
    }

    @Test func aTrashReachedThroughASymlinkedHomeStillCounts() throws {
        let s = try Scratch()
        try s.file("real/.Trash/item", "x")
        try s.symlink("linkedHome", to: s.path("real").path)
        let cmd = HelperRequests.ownershipCommand(path: s.path("linkedHome/.Trash/item").path, uid: 501, gid: 20, home: s.path("linkedHome").path)
        // The command names the real item, never a path through a link.
        #expect(cmd?.last == s.path("real/.Trash/item").path)
    }
}
