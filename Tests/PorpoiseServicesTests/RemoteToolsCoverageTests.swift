import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// An executable shell script in `scratch`.
private func script(_ scratch: Scratch, _ name: String, _ body: String) throws -> URL {
    let u = try scratch.file(name, "#!/bin/sh\n" + body + "\n")
    chmod(u.path, 0o755)
    return u
}

// MARK: - AndroidTools

/// Installing platform-tools and adb's server, without Google or a phone: the download comes from a `LocalFileServer`
/// on 127.0.0.1, Porpoise's folder is a scratch folder and adb is a script. These change AndroidTools' globals, so
/// they take turns.
@Suite(.serialized) final class AndroidToolsCoverageTests {
    let scratch: Scratch
    let support: URL
    let server = LocalFileServer()
    let served: URL
    /// The download this test pointed the installer at, if any.
    private var ownDownload: URL?
    /// The download URL before any of these tests. A test's instance can go away after the next one began, so each
    /// restores the globals only while they still point at its own scratch (else it would undo the next test's).
    private static let savedDownload = AndroidTools.downloadURL

    init() throws {
        _ = Self.savedDownload
        scratch = try Scratch("android")
        support = try scratch.folder("support")
        served = try scratch.folder("served")
        AndroidTools.supportFolderOverride = support
    }

    deinit {
        server.stop()
        if AndroidTools.supportFolderOverride?.path.hasPrefix(scratch.url.path) == true { AndroidTools.supportFolderOverride = nil }
        if let ownDownload, AndroidTools.downloadURL == ownDownload { AndroidTools.downloadURL = Self.savedDownload }
    }

    /// Serves `name` (made by `make`, or missing) and points the installer at it.
    private func serve(_ name: String) throws {
        let base = try #require(server.start(root: served))
        ownDownload = base.appendingPathComponent(name)
        AndroidTools.downloadURL = base.appendingPathComponent(name)
    }

    /// A zip like Google's: platform-tools/adb (and a readme), or without adb.
    private func makeZip(_ name: String, withADB: Bool) throws {
        let src = try scratch.folder("zip-\(name)/platform-tools")
        try scratch.file("zip-\(name)/platform-tools/README", "tools")
        if withADB {
            let adb = try scratch.file("zip-\(name)/platform-tools/adb", "#!/bin/sh\necho fake adb\n")
            chmod(adb.path, 0o755)
        }
        let r = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.path, served.appendingPathComponent(name).path])
        #expect(r.status == 0)
    }

    /// The install's message (nil when it worked).
    private func install(verifying verify: @escaping (URL) -> Bool = { _ in true }) async throws -> String? {
        try await awaitCallback(timeout: 30) { c in AndroidTools.install(verifying: verify) { c.resume(returning: $0) } }
    }

    @Test func installsTheDownloadedToolsAndPrefersThem() async throws {
        // An older install is replaced.
        try scratch.file("support/platform-tools/old-file", "old")
        try makeZip("tools.zip", withADB: true)
        try serve("tools.zip")

        let result = try await install()
        #expect(result == nil)
        let adb = support.appendingPathComponent("platform-tools/adb")
        #expect(FileManager.default.isExecutableFile(atPath: adb.path))
        #expect(scratch.read("support/platform-tools/README") == "tools")
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("platform-tools/old-file").path))
        // Nothing left of the staging folder (removed just after the callback is sent).
        #expect(await eventually(10) { scratch.listing("support") == ["platform-tools"] })
        // Porpoise's own copy comes first.
        #expect(AndroidTools.adbPath == adb.path)
        #expect(AndroidTools.isInstalled)
        #expect(ADBProvider.adbPath == adb.path)
    }

    @Test func rejectsUntrustedADBWithoutReplacingExistingTools() async throws {
        try scratch.file("support/platform-tools/old-file", "keep")
        try makeZip("unsigned.zip", withADB: true)
        try serve("unsigned.zip")
        let result = try await install(verifying: AndroidTools.isTrustedADB)
        #expect(result?.contains("could not be verified") == true)
        #expect(scratch.read("support/platform-tools/old-file") == "keep")
        #expect(await eventually(10) { scratch.listing("support") == ["platform-tools"] })
        #expect(!AndroidTools.isTrustedADB(URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!AndroidTools.isTrustedADB(scratch.path("missing")))
    }

    @Test func aFailedDownloadIsReported() async throws {
        try serve("missing.zip")
        let result = try await install()
        #expect(result?.hasPrefix("The download from Google failed") == true)
        #expect(!FileManager.default.fileExists(atPath: AndroidTools.installDir.path))
    }

    @Test func anArchiveWithoutADBIsNotInstalled() async throws {
        try makeZip("noadb.zip", withADB: false)
        try serve("noadb.zip")
        let result = try await install()
        #expect(result == "The downloaded archive could not be unpacked.")
        #expect(await eventually(10) { scratch.listing("support").isEmpty })
    }

    @Test func anArchiveThatIsNotAZipIsNotInstalled() async throws {
        try scratch.file("served/broken.zip", "not a zip")
        try serve("broken.zip")
        let result = try await install()
        #expect(result == "The downloaded archive could not be unpacked.")
        #expect(await eventually(10) { scratch.listing("support").isEmpty })
    }

    @Test func aFolderThatCannotBeMadeIsReported() async throws {
        // Porpoise's folder is a file: nothing can be unpacked into it.
        AndroidTools.supportFolderOverride = try scratch.file("not a folder", "x")
        try makeZip("tools.zip", withADB: true)
        try serve("tools.zip")
        let result = try await install()
        #expect(result?.isEmpty == false)
        #expect(scratch.read("not a folder") == "x")
    }

    @Test func stopsOnlyAServerItStarted() async throws {
        let log = scratch.path("adb.log")
        // The quit path has a bounded wait. Observe the fixture's acknowledgement after its log write,
        // rather than assuming that returning from quit means that write has finished under load.
        let acknowledgement = scratch.path("adb-finished")
        try #require(mkfifo(acknowledgement.path, 0o600) == 0)
        _ = try scratch.folder("support/platform-tools")
        _ = try script(
            scratch, "support/platform-tools/adb",
            "if [ \"$1\" = kill-server ]; then\necho \"$@\" >> \(RemoteParsing.quote(log.path))\necho done > \(RemoteParsing.quote(acknowledgement.path))\nfi"
        )
        let fd = open(acknowledgement.path, O_RDWR | O_NONBLOCK)
        try #require(fd >= 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "porpoise.adb-test-ack"))
        source.setCancelHandler { close(fd) }
        source.resume()
        defer { source.cancel() }
        AndroidTools.willUseServer()  // the first check is done, so it can't change `startedServer` below
        let saved = AndroidTools.startedServer
        defer { AndroidTools.startedServer = saved }

        AndroidTools.startedServer = false
        AndroidTools.stopServerIfOurs()
        #expect(scratch.read("adb.log") == nil)

        AndroidTools.startedServer = true
        let acknowledged: Bool = try await awaitCallback(timeout: 30) { c in
            source.setEventHandler {
                var byte: UInt8 = 0
                if read(fd, &byte, 1) == 1 { c.resume(returning: true) }
            }
            AndroidTools.stopServerIfOurs()
        }
        #expect(acknowledged == true)
        let contents = scratch.read("adb.log")
        #expect(contents == "kill-server\n", "adb.log: \(String(reflecting: contents))")
    }

    @Test func quittingDoesNotWaitForAHangingADB() throws {
        _ = try scratch.folder("support/platform-tools")
        _ = try script(scratch, "support/platform-tools/adb", "exec /bin/sleep 30")
        AndroidTools.willUseServer()
        let saved = AndroidTools.startedServer
        defer { AndroidTools.startedServer = saved }
        AndroidTools.startedServer = true
        let start = Date()
        AndroidTools.stopServerIfOurs()
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func anADBThatCannotRunIsIgnored() throws {
        // Executable bit set, but not a program macOS can start.
        _ = try scratch.folder("support/platform-tools")
        let adb = try scratch.file("support/platform-tools/adb", "\u{0}\u{1}garbage")
        chmod(adb.path, 0o755)
        AndroidTools.willUseServer()
        let saved = AndroidTools.startedServer
        defer { AndroidTools.startedServer = saved }
        AndroidTools.startedServer = true
        AndroidTools.stopServerIfOurs()
    }

    @Test func providerFindsTheInstalledADB() throws {
        let log = scratch.path("adb.log")
        _ = try scratch.folder("support/platform-tools")
        _ = try script(scratch, "support/platform-tools/adb", "echo \"$@\" >> \(RemoteParsing.quote(log.path))")
        // No adb of its own: the installed one is looked up.
        let p = ADBProvider(serial: "SER1")
        try p.makeFolder(URL(string: "adb://SER1/sdcard/new")!)
        #expect(scratch.read("adb.log") == "-s SER1 shell mkdir -p '/sdcard/new'\n")
        #expect(ADBProvider.devices(timeout: 30).isEmpty)
    }
}

// MARK: - ADB downloads

@Suite struct ADBDownloadCoverageTests {
    @Test func pullsIntoTheFolderWithoutReplacingAnything() throws {
        let s = try Scratch()
        // `adb -s SERIAL pull SRC DST`: writes DST/basename(SRC).
        let adb = try script(s, "adb", "mkdir -p \"$5\" && printf 'from phone' > \"$5/$(basename \"$4\")\"")
        let p = ADBProvider(serial: "SER2", adb: adb.path)
        let into = try s.folder("downloads")

        let got = try p.download(URL(string: "adb://SER2/sdcard/DCIM/photo%201.jpg")!, into: into)
        #expect(got == into.appendingPathComponent("photo 1.jpg"))
        #expect(s.read("downloads/photo 1.jpg") == "from phone")
        #expect(s.listing("downloads") == ["photo 1.jpg"])

        #expect { try p.download(URL(string: "adb://SER2/sdcard/DCIM/photo%201.jpg")!, into: into) } throws: {
            $0.localizedDescription.contains("already exists")
        }
        #expect(s.read("downloads/photo 1.jpg") == "from phone")
    }

    @Test func aFailedPullShowsADBsMessage() throws {
        let s = try Scratch()
        let adb = try script(s, "adb", "echo 'remote object does not exist' >&2; exit 1")
        let p = ADBProvider(serial: "SER3", adb: adb.path)
        #expect { try p.download(URL(string: "adb://SER3/sdcard/gone.txt")!, into: s.url) } throws: {
            $0.localizedDescription.contains("remote object does not exist")
        }
        #expect(s.listing() == ["adb"])
    }
}

// MARK: - FTP folders

/// FTPProvider with folders: what curl is asked for when a folder is downloaded, uploaded, deleted, moved or copied.
@Suite struct FTPFolderCoverageTests {
    let curl: RecordingTool

    init() throws { curl = try RecordingTool() }

    /// Logged in with a password in the URL, so no keychain is read.
    private func provider() -> FTPProvider { FTPProvider(url: URL(string: "ftp://me:pw@h.invalid/")!, curl: curl.path) }

    private static let parent = "drwxr-xr-x 2 ftp ftp 4096 Jan  5  2024 docs\r\n-rw-r--r-- 1 ftp ftp 3 Jan  5  2024 a.txt\r\n"
    private static let docs = "-rw-r--r-- 1 ftp ftp 3 Jan  5  2024 one.txt\r\ndrwxr-xr-x 2 ftp ftp 4096 Jan  5  2024 sub\r\n"
    private static let sub = "-rw-r--r-- 1 ftp ftp 3 Jan  5  2024 two.txt\r\n"

    @Test func downloadsAFolderWithItsSubfolders() throws {
        let local = try Scratch()
        try curl.reply(Self.parent, call: 0)  // is "docs" a folder?
        try curl.reply(Self.docs, call: 1)  // docs/
        try curl.reply("1", call: 2)  // docs/one.txt
        try curl.reply(Self.sub, call: 3)  // docs/sub/
        try curl.reply("2", call: 4)  // docs/sub/two.txt
        let got = try provider().download(URL(string: "ftp://h.invalid/pub/docs")!, into: local.url)
        #expect(got.lastPathComponent == "docs")
        #expect(local.read("docs/one.txt") == "1" && local.read("docs/sub/two.txt") == "2")
        #expect(
            curl.calls.map { $0.args.last } == [
                "ftp://h.invalid/pub/", "ftp://h.invalid/pub/docs/", "ftp://h.invalid/pub/docs/one.txt", "ftp://h.invalid/pub/docs/sub/",
                "ftp://h.invalid/pub/docs/sub/two.txt",
            ])
    }

    @Test func uploadsAFolderAsFoldersAndFiles() throws {
        let local = try Scratch()
        try local.file("site/index.html", "<p>")
        try curl.reply("")
        try provider().upload(local.path("site"), into: URL(string: "ftp://h.invalid/www/")!)
        let calls = curl.calls
        #expect(calls.count == 2)
        #expect(calls[0].args.contains("MKD www/site"))
        #expect(calls[1].args.suffix(3).first == "-T" && calls[1].args.last == "ftp://h.invalid/www/site/index.html")
        let sent = calls[1].args.suffix(2).first ?? ""
        #expect(URL(fileURLWithPath: sent).resolvingSymlinksInPath() == local.path("site/index.html").resolvingSymlinksInPath())
    }

    @Test func deletesAFolderContentsFirst() throws {
        try curl.reply(Self.parent, call: 0)
        try curl.reply(Self.docs, call: 1)
        try curl.reply("", call: 2)  // DELE one.txt
        try curl.reply(Self.sub, call: 3)
        try curl.reply("", call: 4)  // DELE two.txt
        try curl.reply("", call: 5)  // RMD sub
        try curl.reply("", call: 6)  // RMD docs
        try provider().delete([URL(string: "ftp://h.invalid/docs")!])
        let commands = curl.calls.compactMap { c in c.args.firstIndex(of: "-Q").map { c.args[$0 + 1] } }
        #expect(commands == ["DELE docs/one.txt", "DELE docs/sub/two.txt", "RMD docs/sub", "RMD docs"])
    }

    @Test func movesEachItemWithRenames() throws {
        try curl.reply("")
        try provider().move(
            [URL(string: "ftp://h.invalid/a.txt")!, URL(string: "ftp://h.invalid/b%20c.txt")!], into: URL(string: "ftp://h.invalid/dst/")!)
        #expect(
            curl.calls.map { Array($0.args.suffix(7).prefix(4)) } == [
                ["-Q", "RNFR a.txt", "-Q", "RNTO dst/a.txt"], ["-Q", "RNFR b c.txt", "-Q", "RNTO dst/b c.txt"],
            ])
    }

    @Test func copiesThroughALocalTemporaryCopy() throws {
        try curl.reply(Self.parent, call: 0)  // a.txt is a file
        try curl.reply("abc", call: 1)  // its contents
        try curl.reply("", call: 2)  // upload
        try provider().copy([URL(string: "ftp://h.invalid/a.txt")!], into: URL(string: "ftp://h.invalid/dst/")!)
        let upload = try #require(curl.calls.last)
        #expect(upload.args.last == "ftp://h.invalid/dst/a.txt")
        let sent = try #require(upload.args.firstIndex(of: "-T").map { upload.args[$0 + 1] })
        // The temporary copy is gone afterwards.
        #expect(!FileManager.default.fileExists(atPath: sent))
    }

    @Test func titleIsTheLogin() {
        #expect(provider().rootTitle(URL(string: "ftp://h.invalid/")!) == "me@h.invalid")
        #expect(FTPProvider(url: URL(string: "ftp://h.invalid/")!, curl: curl.path).rootTitle(URL(string: "ftp://h.invalid/")!) == "h.invalid")
    }
}

// MARK: - AskPass

@Suite struct AskPassCoverageTests {
    @Test func scriptCallsTheAppWithThePrompt() throws {
        let s = try Scratch()
        // An install path with a quote, `$` and a space stays a plain path.
        let exe = try script(s, "it's $HOME app", "printf '%s|' \"$@\"")
        let path = AskPass.writeScript(in: s.path("support"), exe: exe.path)
        #expect(path == s.path("support/askpass.sh").path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let r = try Shell.run(path, ["Password for me@host:"])
        #expect(r.status == 0)
        #expect(String(decoding: r.out, as: UTF8.self) == "--askpass|Password for me@host:|")
    }
}

// MARK: - NetworkMounts

@Suite struct NetworkMountsCoverageTests {
    @Test(arguments: [
        ("webdav://h.invalid/dav/x", "http://h.invalid/dav/x"), ("dav://h.invalid:8080/", "http://h.invalid:8080/"),
        ("webdavs://h.invalid/s", "https://h.invalid/s"), ("DAVS://h.invalid/", "https://h.invalid/"),
        ("cifs://nas.invalid/share", "smb://nas.invalid/share"), ("smb://nas.invalid/share", "smb://nas.invalid/share"),
        ("afp://nas.invalid/", "afp://nas.invalid/"),
    ])
    func netFSGetsSchemesItKnows(_ typed: String, _ expected: String) {
        #expect(NetworkMounts.mountURL(URL(string: typed)!).absoluteString == expected)
    }

    @Test func aMountedShareIsFoundWithThePathInside() {
        let vol = URL(fileURLWithPath: "/Volumes/share", isDirectory: true)
        let remount = URL(string: "smb://NAS.invalid/share")!
        #expect(
            NetworkMounts.path(of: URL(string: "smb://nas.invalid/share/a/b%20c")!, onVolume: vol, mountedFrom: remount)?.path
                == "/Volumes/share/a/b c")
        #expect(NetworkMounts.path(of: URL(string: "smb://nas.invalid/share")!, onVolume: vol, mountedFrom: remount)?.path == "/Volumes/share")
        // No share asked for: any share of that server will do.
        #expect(NetworkMounts.path(of: URL(string: "smb://nas.invalid")!, onVolume: vol, mountedFrom: remount)?.path == "/Volumes/share")
    }

    @Test func otherServersSharesAndSchemesDoNotMatch() {
        let vol = URL(fileURLWithPath: "/Volumes/share", isDirectory: true)
        let remount = URL(string: "smb://nas.invalid/share")!
        #expect(NetworkMounts.path(of: URL(string: "smb://other.invalid/share")!, onVolume: vol, mountedFrom: remount) == nil)
        #expect(NetworkMounts.path(of: URL(string: "smb://nas.invalid/other")!, onVolume: vol, mountedFrom: remount) == nil)
        #expect(NetworkMounts.path(of: URL(string: "afp://nas.invalid/share")!, onVolume: vol, mountedFrom: remount) == nil)
    }

    @Test func aServerThatIsNotMountedIsNotFound() {
        #expect(NetworkMounts.mountedVolume(for: URL(string: "smb://never-mounted.invalid/share")!) == nil)
    }
}

// MARK: - NetworkBrowser

/// Bonjour's callbacks called directly, with services that answer for themselves: nothing is looked up on the
/// network (no Local Network prompt).
@Suite struct NetworkBrowserCoverageTests {
    final class Service: NetService {
        let host: String?
        let fixedPort: Int
        private(set) var resolveAsked = false

        init(_ type: String, _ name: String, host: String?, port: Int) {
            self.host = host
            fixedPort = port
            // Only made, never published or resolved.
            super.init(domain: "local.", type: type, name: name, port: Int32(port))
        }

        override var hostName: String? { host }
        override var port: Int { fixedPort }
        override func resolve(withTimeout timeout: TimeInterval) { resolveAsked = true }
    }

    let browser = NetworkBrowser()
    let bonjour = NetServiceBrowser()

    @Test func foundServicesAreResolvedThenListed() {
        let smb = Service("_smb._tcp.", "NAS", host: "nas.local.", port: 445)
        browser.netServiceBrowser(bonjour, didFind: smb, moreComing: false)
        #expect(smb.resolveAsked && smb.delegate === browser)
        browser.netServiceDidResolveAddress(smb)
        #expect(browser.servers.map(\.url.absoluteString) == ["smb://nas.local/"])
        #expect(browser.items.map(\.name) == ["NAS (SMB)"])
        #expect(browser.items.first?.isDirectory == true)
        // Resolved twice: listed once.
        browser.netServiceDidResolveAddress(smb)
        #expect(browser.servers.count == 1)
    }

    @Test func onlyAnUnusualPortIsPartOfTheURL() {
        browser.netServiceDidResolveAddress(Service("_sftp-ssh._tcp.", "Pi", host: "pi.local.", port: 2222))
        browser.netServiceDidResolveAddress(Service("_webdavs._tcp.", "Dav", host: "dav.local", port: 443))
        browser.netServiceDidResolveAddress(Service("_ftp._tcp.", "Ftp", host: "ftp.local", port: 0))
        #expect(browser.servers.map(\.url.absoluteString) == ["sftp://pi.local:2222/", "webdavs://dav.local/", "ftp://ftp.local/"])
        #expect(browser.servers.map(\.kind) == ["SFTP server", "WebDAV server (secure)", "FTP server"])
    }

    @Test func unresolvedOrUnknownServicesAreNotListed() {
        let unresolved = Service("_smb._tcp.", "NoHost", host: nil, port: 445)
        browser.netServiceBrowser(bonjour, didFind: unresolved, moreComing: true)
        browser.netService(unresolved, didNotResolve: [:])
        browser.netServiceDidResolveAddress(unresolved)
        browser.netServiceDidResolveAddress(Service("_printer._tcp.", "Printer", host: "printer.local", port: 515))
        #expect(browser.servers.isEmpty && browser.items.isEmpty)
    }

    @Test func aRemovedServiceTakesOnlyItsOwnEntry() {
        // One machine offering SMB and SSH under one name.
        let smb = Service("_smb._tcp.", "Mac", host: "mac.local", port: 445)
        let ssh = Service("_ssh._tcp.", "Mac", host: "mac.local", port: 22)
        browser.netServiceDidResolveAddress(smb)
        browser.netServiceDidResolveAddress(ssh)
        #expect(browser.servers.count == 2)
        browser.netServiceBrowser(bonjour, didRemove: smb, moreComing: false)
        #expect(browser.servers.map(\.url.absoluteString) == ["sftp://mac.local/"])
    }
}
