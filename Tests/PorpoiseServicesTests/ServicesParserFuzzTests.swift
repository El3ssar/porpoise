import Foundation
import Testing
@testable import PorpoiseServices
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Seeded fuzzing of the services' parsers (see `Fuzzer`): typed remote locations, ffmpeg's output and the SSH
/// listing. No crash, and simple invariants hold.
@Suite struct ServicesParserFuzzTests {
    private let cases = 3000

    @Test func typedRemoteLocations() {
        #expect(RemoteFS.parseTyped("user@host:/srv/a b")?.absoluteString == "sftp://user@host/srv/a%20b")
        #expect(RemoteFS.parseTyped("host.lan:docs")?.absoluteString == "sftp://host.lan/~/docs")
        #expect(RemoteFS.parseTyped("fish://h/x")?.absoluteString == "sftp://h/x")
        // Paths that merely contain "://" stay paths.
        #expect(RemoteFS.parseTyped("~/notes/http://x") == nil)
        #expect(RemoteFS.parseTyped("/tmp/a://b") == nil)

        var f = Fuzzer(seed: 11)
        var v = Violations()
        let samples = ["user@host:/path/to dir", "host.example:file", "sftp://u@h:22/x", "fish://h/~/a b", "ssh://h//x",
                       "~/x", "/local/path", "ftp://h/%20"]
        for _ in 0..<cases {
            let t = f.int(3) == 0 ? f.string(max: 8) : f.mutate(f.pick(samples))
            guard let u = RemoteFS.parseTyped(t) else { continue }
            v.check(u.scheme != nil, "\(t.debugDescription) → \(u) has no scheme")
            v.check(!["fish", "ssh", "scp"].contains(u.scheme?.lowercased() ?? ""), "\(t.debugDescription) → \(u) kept its alias scheme")
            _ = RemoteFS.isRemote(u)
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    @Test func ffmpegOutput() {
        var f = Fuzzer(seed: 12)
        var v = Violations()
        let samples = ["Input #0, matroska,webm, from 'file:/x.mkv':", "  Duration: 00:34:40.56, start: 0.000000, bitrate: 5 kb/s",
                       "  Stream #0:0(eng): Video: hevc (Main 10), yuv420p10le", "  Stream #0:1: Audio: aac (LC), 48000 Hz",
                       "  Stream #0:2: Video: mjpeg, (attached pic)"]
        for _ in 0..<cases {
            let t = f.text(samples: samples, lines: 8)
            if let d = VideoPreview.parseDuration(t) { v.check(!d.isInfinite || t.contains("inf") || t.contains("e"), "duration \(d) from \(t.debugDescription)") }
            let c = VideoPreview.parseCodecs(t)
            v.check(!c.video.contains(" ") && !c.audio.contains(" "), "codecs \(c) from \(t.debugDescription)")
            v.check(VideoPreview.parseContainer(t).allSatisfy { !$0.isEmpty && !$0.contains(" ") }, "containers from \(t.debugDescription)")
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    /// Whatever the server prints, listed items are single names inside the folder.
    @Test func sshListingOutput() {
        var f = Fuzzer(seed: 13)
        var v = Violations()
        let folder = URL(string: "sftp://host/home/me")!
        let samples = ["fd\t4096\t1700000000.5\t755\tme\tstaff\t\t./dir\0", "Regular File\t1\t1700000000\t644\tme\tstaff\t\t./f\n\0",
                       "__BSD__\n", "__GNU__\n"]
        for _ in 0..<cases {
            let t = f.text(samples: samples, separator: "") + f.pick(["__BSD__\n", "__GNU__\n", ""])
            for it in SSHProvider.parseListing(t, folder: folder) {
                v.check(RemoteParsing.isSafeName(it.name), "unsafe \(it.name.debugDescription)")
                v.check(it.url.path == "/home/me/" + it.name, "\(it.url.path.debugDescription) for \(it.name.debugDescription)")
                v.check(it.url.host == "host" && it.url.scheme == "sftp", "\(it.url) left the server")
            }
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }
}
