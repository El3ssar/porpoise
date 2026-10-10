import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// SSHProvider against a real sshd on 127.0.0.1 (see `SSHServer`). The server runs on this Mac, so its files are
/// set up and checked directly on disk, and its shell is macOS's: the listing takes the BSD `stat` path.
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer)
struct SSHProviderTests {
    let server = SSHServer.current!
    let fm = FileManager.default

    /// Names that break naive quoting, parsing or option handling.
    static let hostileNames = ["with space.txt", "it's \"quoted\".txt", "new\nline", "ends in newline\n", "tab\there",
                               "-rf", "--help", "ünïcødé 📁", "*", "$(touch pwned)", "`touch pwned`", "a\\b", ".hidden"]

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func listsHostileNamesLinksAndHiddenFiles() throws {
        let dir = try server.folder()
        for name in Self.hostileNames { try write(name, to: dir.appendingPathComponent(name)) }
        try fm.createDirectory(at: dir.appendingPathComponent("sub folder"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("to-folder").path, withDestinationPath: "sub folder")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("to-file").path, withDestinationPath: "with space.txt")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")

        let items = try server.provider().list(server.url(dir.path, isDirectory: true))

        #expect(Set(items.map(\.name)) == Set(Self.hostileNames + ["sub folder", "to-folder", "to-file", "dangling"]))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pwned").path))   // no name was run as a command
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["sub folder"]?.isDirectory == true)
        #expect(byName["with space.txt"]?.size == Int64("with space.txt".utf8.count))
        #expect(byName[".hidden"]?.isHidden == true && byName["-rf"]?.isHidden == false)
        #expect(byName["to-file"]?.isSymlink == true && byName["to-file"]?.isDirectory == false)
        #expect(byName["to-file"]?.linkDestination == "with space.txt")
        #expect(byName["dangling"]?.isSymlink == true && byName["dangling"]?.linkDestination == "nowhere")
        // A link to a folder is browsed like the folder.
        #expect(byName["to-folder"]?.isSymlink == true && byName["to-folder"]?.isDirectory == true)
        for item in items {
            #expect(item.url.scheme == "sftp" && item.url.port == server.port)
            #expect(item.url.lastPathComponent == item.name)
            #expect(item.url.deletingLastPathComponent().path == dir.path)
        }
    }

    @Test func listsAnEmptyFolderAsEmpty() throws {
        // The BSD path globs `.* *`: an unmatched "*" must not show up as a file.
        let dir = try server.folder()
        #expect(try server.provider().list(server.url(dir.path, isDirectory: true)).isEmpty)
    }

    @Test func listingAMissingFolderFails() throws {
        let dir = try server.folder()
        #expect(throws: (any Error).self) { try server.provider().list(server.url(dir.appendingPathComponent("gone").path)) }
    }

    @Test func homeRelativePathsUseTheRemoteHome() throws {
        let dir = try server.folder()
        try write("x", to: dir.appendingPathComponent("in home.txt"))
        let p = server.provider()
        // "/~/name" is the scp-style path relative to the remote HOME (here the scratch home).
        let viaHome = try p.list(server.url("/~/" + dir.lastPathComponent, isDirectory: true))
        #expect(viaHome.map(\.name) == ["in home.txt"])
        #expect(try p.list(server.url("/~")).contains { $0.name == dir.lastPathComponent })
        try p.makeFolder(server.url("/~/" + dir.lastPathComponent + "/made it"))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("made it").path))
    }

    @Test func downloadsFilesFoldersAndLinkedFiles() throws {
        let dir = try server.folder()
        let local = try Scratch()
        try write("hello", to: dir.appendingPathComponent("-report [1] it's.txt"))
        try write("deep", to: dir.appendingPathComponent("tree/inner folder/deep.txt"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link.txt").path, withDestinationPath: "-report [1] it's.txt")
        let p = server.provider()

        let file = try p.download(server.url(dir.appendingPathComponent("-report [1] it's.txt")), into: local.url)
        #expect(file == local.path("-report [1] it's.txt"))
        #expect(local.read("-report [1] it's.txt") == "hello")

        _ = try p.download(server.url(dir.appendingPathComponent("tree")), into: local.url)
        #expect(local.read("tree/inner folder/deep.txt") == "deep")

        // A link to a file arrives as the file itself, so opening it opens its content.
        let linked = try p.download(server.url(dir.appendingPathComponent("link.txt")), into: local.url)
        #expect(try fm.attributesOfItem(atPath: linked.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(local.read("link.txt") == "hello")

        // Never over an existing local item, and nothing is left behind in the folder.
        try local.file("existing.txt", "mine")
        try write("theirs", to: dir.appendingPathComponent("existing.txt"))
        #expect(throws: (any Error).self) { try p.download(server.url(dir.appendingPathComponent("existing.txt")), into: local.url) }
        #expect(local.read("existing.txt") == "mine")
        #expect(local.listing() == ["-report [1] it's.txt", "existing.txt", "link.txt", "tree"])
    }

    @Test func downloadingAMissingFileFailsCleanly() throws {
        let dir = try server.folder()
        let local = try Scratch()
        #expect(throws: (any Error).self) { try server.provider().download(server.url(dir.appendingPathComponent("gone.txt")), into: local.url) }
        #expect(local.listing().isEmpty)
    }

    @Test func uploadsFilesAndFoldersReplacingSameNamedFiles() throws {
        let dir = try server.folder()
        let local = try Scratch()
        let p = server.provider()
        let remoteDir = server.url(dir.path)

        let file = try local.file("-n [1] it's.txt", "first")
        try p.upload(file, into: remoteDir)
        #expect(read(dir.appendingPathComponent("-n [1] it's.txt")) == "first")
        try local.file("-n [1] it's.txt", "second")
        try p.upload(file, into: remoteDir)
        #expect(read(dir.appendingPathComponent("-n [1] it's.txt")) == "second")

        try local.file("project/src/main.swift", "print(1)")
        try p.upload(local.path("project"), into: remoteDir)
        #expect(read(dir.appendingPathComponent("project/src/main.swift")) == "print(1)")
    }

    @Test func uploadsCarryNoAppleDoubleFiles() throws {
        let dir = try server.folder()
        let local = try Scratch()
        let file = try local.file("tagged.txt", "x")
        #expect(setxattr(file.path, "com.apple.metadata:porpoise-test", "1", 1, 0, 0) == 0)
        try server.provider().upload(file, into: server.url(dir.path))
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["tagged.txt"])   // no "._tagged.txt"
    }

    @Test func makesRenamesAndDeletes() throws {
        let dir = try server.folder()
        let p = server.provider()

        try p.makeFolder(server.url(dir.appendingPathComponent("a b/c'd $x").path))
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("a b/c'd $x").path, isDirectory: &isDir) && isDir.boolValue)

        try write("old", to: dir.appendingPathComponent("old.txt"))
        try p.rename(server.url(dir.appendingPathComponent("old.txt")), to: "-new it's.txt")
        #expect(read(dir.appendingPathComponent("-new it's.txt")) == "old")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("old.txt").path))

        try p.delete([server.url(dir.appendingPathComponent("a b")), server.url(dir.appendingPathComponent("-new it's.txt"))])
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func renameNeverReplacesAnExistingItem() throws {
        let dir = try server.folder()
        let p = server.provider()
        try write("a", to: dir.appendingPathComponent("a.txt"))
        try write("b", to: dir.appendingPathComponent("b.txt"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "nowhere")

        #expect { try p.rename(server.url(dir.appendingPathComponent("a.txt")), to: "b.txt") } throws: {
            $0.localizedDescription.contains("already exists")
        }
        // A dangling link is an existing item too.
        #expect(throws: (any Error).self) { try p.rename(server.url(dir.appendingPathComponent("a.txt")), to: "link") }
        #expect(read(dir.appendingPathComponent("a.txt")) == "a" && read(dir.appendingPathComponent("b.txt")) == "b")
    }

    @Test(arguments: ["", ".", "..", "a/b", "../escape", "line\nbreak", "cr\rhere"])
    func renameRefusesNamesThatAreNotOneComponent(_ name: String) throws {
        let dir = try server.folder()
        try write("a", to: dir.appendingPathComponent("a.txt"))
        #expect(throws: (any Error).self) { try server.provider().rename(server.url(dir.appendingPathComponent("a.txt")), to: name) }
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["a.txt"])
    }

    @Test func copiesAndMovesWithinTheServer() throws {
        let dir = try server.folder()
        let p = server.provider()
        try write("one", to: dir.appendingPathComponent("-one it's.txt"))
        try write("two", to: dir.appendingPathComponent("folder/two.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("dest dir"), withIntermediateDirectories: false)
        let dest = server.url(dir.appendingPathComponent("dest dir"))

        try p.copy([server.url(dir.appendingPathComponent("-one it's.txt")), server.url(dir.appendingPathComponent("folder"))], into: dest)
        #expect(read(dir.appendingPathComponent("dest dir/-one it's.txt")) == "one")
        #expect(read(dir.appendingPathComponent("dest dir/folder/two.txt")) == "two")
        #expect(read(dir.appendingPathComponent("-one it's.txt")) == "one")   // the copy left the original

        try fm.createDirectory(at: dir.appendingPathComponent("moved"), withIntermediateDirectories: false)
        try p.move([server.url(dir.appendingPathComponent("-one it's.txt"))], into: server.url(dir.appendingPathComponent("moved")))
        #expect(read(dir.appendingPathComponent("moved/-one it's.txt")) == "one")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("-one it's.txt").path))
    }

    @Test func movingIntoAMissingFolderFailsInsteadOfRenaming() throws {
        let dir = try server.folder()
        let p = server.provider()
        try write("x", to: dir.appendingPathComponent("x.txt"))
        let missing = server.url(dir.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try p.move([server.url(dir.appendingPathComponent("x.txt"))], into: missing) }
        #expect(throws: (any Error).self) { try p.copy([server.url(dir.appendingPathComponent("x.txt"))], into: missing) }
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["x.txt"])
    }

    @Test func refusesToDeleteTheTopFolders() throws {
        let p = server.provider()
        for top in ["/", "/~", "/~/"] {
            #expect(throws: (any Error).self) { try p.delete([server.url(top)]) }
        }
        #expect(fm.fileExists(atPath: server.home.path))
    }

    @Test func reusesOneConnectionUntilDisconnected() throws {
        let dir = try server.folder()
        let p = server.provider()
        p.disconnect()   // a connection left by an earlier test
        let before = server.logins

        for _ in 0..<4 { _ = try p.list(server.url(dir.path)) }
        #expect(server.logins == before + 1)
        #expect(try fm.contentsOfDirectory(atPath: server.controlDir.path).count == 1)   // the master's socket

        p.disconnect()
        #expect(try fm.contentsOfDirectory(atPath: server.controlDir.path).isEmpty)
        _ = try p.list(server.url(dir.path))
        #expect(server.logins == before + 2)
    }

    @Test func doesNotTrustAnUnknownHostKey() throws {
        // The same server with an empty known_hosts: strict checking refuses it rather than asking or recording it.
        let empty = try Scratch()
        let knownHosts = try empty.file("known_hosts")
        let p = SSHProvider(url: server.url("/"), isolation: .init(options: [
            "-F", "/dev/null", "-i", server.scratch.path("client_key").path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes", "-o", "ControlPath=none",
        ], controlDir: empty.url))
        #expect { try p.list(server.url(server.home.path)) } throws: {
            $0.localizedDescription.contains("Host key verification failed")
        }
        #expect(empty.read("known_hosts") == "")
    }
}

/// What SSHProvider decides before it runs anything.
@Suite struct SSHProviderCommandTests {
    let provider = SSHProvider(url: URL(string: "sftp://me@example.invalid/")!)

    @Test func pathsBecomeOneQuotedShellWord() {
        #expect(provider.shellPath(URL(string: "sftp://h/srv/it's%20here")!) == "'/srv/it'\\''s here'")
        #expect(provider.shellPath(URL(string: "sftp://h/srv/$(rm%20-rf%20~)")!) == "'/srv/$(rm -rf ~)'")
        #expect(provider.shellPath(URL(string: "sftp://h/-rf")!) == "'/-rf'")
    }

    @Test func homePathsKeepHomeOutsideTheQuotes() {
        #expect(provider.shellPath(URL(string: "sftp://h/~")!) == "\"$HOME\"")
        #expect(provider.shellPath(URL(string: "sftp://h")!) == "\"$HOME\"")
        #expect(provider.shellPath(URL(string: "sftp://h/~/a%20b")!) == "\"$HOME\"/'a b'")
        // "~" inside a name is only a character.
        #expect(provider.shellPath(URL(string: "sftp://h/srv/~x")!) == "'/srv/~x'")
    }

    @Test(arguments: ["sftp://-oProxyCommand=touch@host/", "sftp://me@-oProxyCommand=x/"])
    func refusesHostsAndUsersThatLookLikeOptions(_ url: String) throws {
        let p = SSHProvider(url: try #require(URL(string: url)))
        #expect { try p.list(URL(string: url)!) } throws: { $0.localizedDescription.contains("Invalid server name") }
    }

    @Test func titleIsUserAtHost() {
        #expect(provider.rootTitle(URL(string: "sftp://me@example.invalid/")!) == "me@example.invalid")
        #expect(SSHProvider(url: URL(string: "sftp://example.invalid")!).rootTitle(URL(string: "sftp://example.invalid")!) == "example.invalid")
    }
}
