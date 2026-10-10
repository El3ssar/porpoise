import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// URL handling and the provider registry. Hosts are `.invalid`, so nothing here connects anywhere; FTP URLs carry
/// a password so no Keychain is read.
@Suite(.serialized) struct RemoteFSTests {
    @Test func whichSchemesAreBrowsedByAProvider() {
        for s in ["sftp://h/", "SSH://h/", "fish://h/", "scp://h/", "ftp://h/", "ftps://h/", "adb://serial/"] {
            #expect(RemoteFS.isRemote(URL(string: s)!), "\(s)")
        }
        for s in ["file:///tmp", "smb://nas/share", "afp://nas/", "https://example.invalid/", "/tmp"] {
            #expect(!RemoteFS.isRemote(URL(string: s)!), "\(s)")
        }
        #expect(NetworkMounts.needsMount(URL(string: "SMB://nas/share")!) && NetworkMounts.needsMount(URL(string: "davs://h/")!))
        #expect(!NetworkMounts.needsMount(URL(string: "sftp://h/")!))
    }

    @Test(arguments: [
        ("me@host.invalid:/srv/www", "sftp://me@host.invalid/srv/www"),
        ("host.invalid:docs/my notes", "sftp://host.invalid/~/docs/my%20notes"),
        ("me@host.invalid:", "sftp://me@host.invalid/~/"),
        ("  me@host.invalid:/x  ", "sftp://me@host.invalid/x"),
        ("fish://me@host.invalid/a", "sftp://me@host.invalid/a"),
        ("ssh://host.invalid:2222/a", "sftp://host.invalid:2222/a"),
        ("ftp://host.invalid/pub/a b", "ftp://host.invalid/pub/a%20b"),
    ])
    func typedLocationsBecomeURLs(_ typed: String, _ expected: String) {
        #expect(RemoteFS.parseTyped(typed)?.absoluteString == expected)
    }

    @Test(arguments: ["/usr/local", "~/Documents", "Documents", "C:stuff"])
    func localLookingTextIsNotARemoteLocation(_ typed: String) {
        #expect(RemoteFS.parseTyped(typed) == nil)
    }

    @Test func oneProviderPerSchemeUserHostAndPort() throws {
        let urls = ["sftp://me@a.invalid/x", "sftp://me@a.invalid/y/z", "sftp://you@a.invalid/", "sftp://me@a.invalid:2222/",
                    "ftp://me:pw@a.invalid/", "adb://SERIAL123/", "adb://192.168.1.5:5555/"].map { URL(string: $0)! }
        defer { urls.forEach { RemoteFS.use(nil, for: $0) } }
        let p = try urls.map { try #require(RemoteFS.provider(for: $0)) }

        #expect(p[0] === p[1])                                   // same connection, any path
        #expect(p[0] !== p[2] && p[0] !== p[3])                  // another user or port is another connection
        #expect(p[0] is SSHProvider && p[4] is FTPProvider)
        #expect((p[5] as? ADBProvider)?.serial == "SERIAL123")
        #expect((p[6] as? ADBProvider)?.serial == "192.168.1.5:5555")   // network serials are host:port
        #expect(RemoteFS.provider(for: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func displayNames() {
        let root = URL(string: "sftp://me@names.invalid/")!
        defer { RemoteFS.use(nil, for: root) }
        #expect(RemoteFS.displayName(for: root) == "me@names.invalid")
        #expect(RemoteFS.displayName(for: URL(string: "sftp://me@names.invalid/srv/my%20site")!) == "my site")
        #expect(RemoteFS.displayName(for: URL(string: "ftp://u:pw@names.invalid/")!) == "u@names.invalid")
    }

    // MARK: Staged downloads

    @Test func stagedDownloadKeepsOnlyTheRequestedItem() throws {
        let local = try Scratch()
        // A server may send more than asked for (a tar stream can hold anything): only `report.txt` is kept.
        let got = try RemoteFS.downloadStaged("report.txt", into: local.url) { staging in
            try Data("ok".utf8).write(to: staging.appendingPathComponent("report.txt"))
            try Data("extra".utf8).write(to: staging.appendingPathComponent("extra.sh"))
        }
        #expect(got == local.path("report.txt"))
        #expect(local.listing() == ["report.txt"])   // no extra file, no staging folder
    }

    @Test func stagedDownloadNeverReplacesALocalItem() throws {
        let local = try Scratch()
        try local.file("report.txt", "mine")
        #expect { try RemoteFS.downloadStaged("report.txt", into: local.url) { staging in
            try Data("theirs".utf8).write(to: staging.appendingPathComponent("report.txt"))
        } } throws: { $0.localizedDescription.contains("already exists") }
        #expect(local.read("report.txt") == "mine")
        #expect(local.listing() == ["report.txt"])
    }

    @Test func stagedDownloadCleansUpWhenTheFetchFails() throws {
        let local = try Scratch()
        struct Lost: Error {}
        #expect(throws: Lost.self) { try RemoteFS.downloadStaged("a.txt", into: local.url) { _ in throw Lost() } }
        #expect(local.listing().isEmpty)
    }

    @Test(arguments: ["", ".", "..", "../up.txt", "a/b", "nl\nname", "cr\rname", "crlf\r\nname", "a/\u{301}b"])
    func stagedDownloadRefusesUnsafeNames(_ name: String) throws {
        let local = try Scratch()
        var fetched = false
        #expect(throws: (any Error).self) { try RemoteFS.downloadStaged(name, into: local.url) { _ in fetched = true } }
        #expect(!fetched && local.listing().isEmpty)
    }
}
