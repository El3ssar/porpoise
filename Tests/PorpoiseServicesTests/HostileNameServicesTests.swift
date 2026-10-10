import Foundation
import Testing
@testable import PorpoiseServices
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Hostile names (see `HostileNames`) through the services' own scripts, run for real on local files: the SSH listing
/// script, the administrator AppleScript, staged downloads and ffmpeg's arguments.
@Suite(.serialized) struct HostileNameServicesTests {
    private let scratch: Scratch
    private let names = HostileNames.all

    init() throws { scratch = try Scratch("HostileNameServices") }

    /// A remote URL for a local path, as the app builds it from a listing.
    private func remote(_ path: String) -> URL {
        URL(string: "sftp://host" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
    }

    /// "" when the names are the same; otherwise what is missing and what is extra.
    private func difference(_ got: [String], _ want: [String]) -> String {
        let g = Set(got), w = Set(want)
        return g == w && got.count == want.count ? ""
            : "missing \(w.subtracting(g).map(\.debugDescription)), extra \(g.subtracting(w).map(\.debugDescription)), \(got.count) vs \(want.count)"
    }

    @discardableResult
    private func populate(_ folder: String) throws -> URL {
        let dir = try scratch.folder(folder)
        for (i, n) in names.enumerated() { try Data("\(i)".utf8).write(to: dir.appendingPathComponent(n)) }
        return dir
    }

    /// SSHProvider's listing script, run the way ssh runs it (the login shell reads `sh -c QUOTED`), on a folder of
    /// hostile names, and parsed back. Plain macOS tools, so this is the BSD `stat` branch a macOS server takes.
    @Test func sshListingScriptRoundTrips() throws {
        let dir = try populate("$(echo PWNED) folder\n'x'")
        try scratch.folder("$(echo PWNED) folder\n'x'/sub dir\n")
        try scratch.symlink("$(echo PWNED) folder\n'x'/link\r", to: "target with spaces")
        let ssh = SSHProvider(url: remote("/"))
        let folder = remote(dir.path)
        #expect(folder.path == dir.path)
        let script = SSHProvider.listScript(ssh.shellPath(folder))
        for login in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let r = try runTool(login, ["-c", "sh -c " + RemoteParsing.quote(script)], env: ["PATH": "/usr/bin:/bin"])
            #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
            let items = SSHProvider.parseListing(String(decoding: r.out, as: UTF8.self), folder: folder)
            #expect(items.count == names.count + 2, "\(login)")
            #expect(difference(items.map(\.name), names + ["sub dir\n", "link\r"]) == "", "\(login)")
            for it in items {
                #expect(it.url.deletingLastPathComponent().path == dir.path)
                if let i = names.firstIndex(of: it.name) {
                    #expect(it.size == Int64("\(i)".utf8.count) && !it.isDirectory && !it.isSymlink, "\(it.name.debugDescription)")
                }
            }
            #expect(items.first { $0.name == "sub dir\n" }?.isDirectory == true)
            let link = items.first { $0.name == "link\r" }
            #expect(link?.isSymlink == true && link?.linkDestination == "target with spaces")
        }
    }

    /// Paths under the remote home ("/~/…") become `"$HOME"/'…'`.
    @Test func homeRelativeShellPaths() throws {
        try populate("home/in home")
        let ssh = SSHProvider(url: remote("/"))
        let script = SSHProvider.listScript(ssh.shellPath(remote("/~/in home")))
        let r = try runTool("/bin/sh", ["-c", script], env: ["PATH": "/usr/bin:/bin", "HOME": scratch.path("home").path])
        #expect(r.status == 0)
        let items = SSHProvider.parseListing(String(decoding: r.out, as: UTF8.self), folder: remote("/~/in home"))
        #expect(difference(items.map(\.name), names) == "")
        #expect(ssh.shellPath(remote("/~")) == "\"$HOME\"")
    }

    /// The administrator script's quoting, run for real without the administrator part: AppleScript literal around a
    /// shell line of quoted arguments. Each hostile name is copied with /bin/cp and arrives intact.
    @Test func administratorScriptQuotingRunsTheRightCommand() throws {
        let src = try populate("admin-src")
        let dst = try scratch.folder("admin-dst")
        let commands = names.map { ["/bin/cp", "--", src.appendingPathComponent($0).path, dst.appendingPathComponent($0).path] }
            + [["/usr/bin/chflags", "nouchg", src.appendingPathComponent("missing").path]]   // best effort: may fail
        let script = FileOperationsController.administratorScript(commands)
        let suffix = " with administrator privileges"
        #expect(script.hasSuffix(suffix))
        let r = try runTool("/usr/bin/osascript", ["-e", String(script.dropLast(suffix.count))])
        #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
        for (i, n) in names.enumerated() {
            let got = try? Data(contentsOf: dst.appendingPathComponent(n))
            #expect(got.map { String(decoding: $0, as: UTF8.self) } == "\(i)", "\(n.debugDescription)")
        }
        #expect(scratch.listing("admin-dst").count == names.count)
    }

    /// A staged download keeps the name it asked for; names that would split an FTP command are refused.
    @Test func stagedDownloadsKeepHostileNames() throws {
        let into = try scratch.folder("downloads")
        for (i, n) in names.enumerated() {
            if n.unicodeScalars.contains("\n") || n.unicodeScalars.contains("\r") {
                #expect(throws: (any Error).self) { try RemoteFS.downloadStaged(n, into: into) { _ in } }
                continue
            }
            let got = try RemoteFS.downloadStaged(n, into: into) { staging in
                try Data("\(i)".utf8).write(to: staging.appendingPathComponent(n))
                try Data("extra".utf8).write(to: staging.appendingPathComponent("not asked for"))
            }
            #expect(got.lastPathComponent == n)
            #expect(String(decoding: try Data(contentsOf: got), as: UTF8.self) == "\(i)")
        }
        #expect(!scratch.listing("downloads").contains { $0.hasPrefix(".porpoise-download-") || $0 == "not asked for" })
        // Asking for the same name again never replaces the first one.
        #expect(throws: (any Error).self) {
            try RemoteFS.downloadStaged("-rf", into: into) { try Data("new".utf8).write(to: $0.appendingPathComponent("-rf")) }
        }
    }

    /// ffmpeg reads its input as "file:" + path, one argument, so "concat:…" or "-i" names are only names.
    @Test func ffmpegInputIsOneLiteralArgument() {
        for n in names {
            let input = scratch.path(n)
            let args = VideoPreview.streamArguments(input: input, codecs: ("h264", "aac"), output: scratch.path("out/index.m3u8"))
            let i = args.firstIndex(of: "-i")!
            #expect(args[i + 1] == "file:" + input.path)
            #expect(args.filter { $0 == "-i" }.count == 1)
        }
    }
}
