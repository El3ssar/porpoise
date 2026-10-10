import Foundation
import Testing
import PorpoiseTestSupport
@testable import PorpoiseServices

/// What VideoPreview decides from ffmpeg's output, and the arguments it runs ffmpeg with. No ffmpeg needed.
@Suite struct VideoPreviewParsingTests {
    @Test func videoExtensions() {
        for e in ["mkv", "MKV", "webm", "avi", "Avi", "wmv", "flv", "ts", "y4m"] { #expect(VideoPreview.isVideoExtension(e), "\(e)") }
        for e in ["mp4", "mov", "m4v", "txt", "", "mkv ", ".mkv"] { #expect(!VideoPreview.isVideoExtension(e), "\(e)") }
    }

    @Test func durations() {
        #expect(VideoPreview.parseDuration("  Duration: 00:34:40.56, start: 0.000000, bitrate: 1 kb/s") == 2080.56)
        #expect(VideoPreview.parseDuration("Duration: 01:00:00.00,") == 3600)
        #expect(VideoPreview.parseDuration("Duration: 00:00:01.5") == 1.5)   // no comma: to the end
        #expect(VideoPreview.parseDuration("Duration: 123:00:00.00,") == 442_800.0)
        for bad in ["Duration: N/A, start: 0", "Duration: 00:01, x", "Duration: 1:2:3:4,", "Duration: aa:bb:cc,", "no duration here", "",
                    "Duration: ,"] {
            #expect(VideoPreview.parseDuration(bad) == nil, "\(bad)")
        }
    }

    @Test func containers() {
        #expect(VideoPreview.parseContainer("Input #0, matroska,webm, from 'file:/x.mkv':") == ["matroska", "webm"])
        #expect(VideoPreview.parseContainer("Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'a'") == ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"])
        #expect(VideoPreview.parseContainer("Input #0, avi, from 'a'") == ["avi"])
        #expect(VideoPreview.parseContainer("garbage") == [])
        #expect(VideoPreview.parseContainer("") == [])
    }

    @Test func codecs() {
        let text = """
            Input #0, matroska,webm, from 'file:/x.mkv':
              Stream #0:0: Video: mjpeg (Baseline), yuvj420p, 600x600 (attached pic)
              Stream #0:1(eng): Video: h264 (High), yuv420p(progressive), 1920x1080
              Stream #0:2(eng): Audio: aac (LC), 48000 Hz, stereo
              Stream #0:3(jpn): Audio: opus, 48000 Hz
              Stream #0:4: Video: hevc (Main 10)
            """
        #expect(VideoPreview.parseCodecs(text) == ("h264", "aac"))
        #expect(VideoPreview.parseCodecs("  Stream #0:0: Video: hevc (Main), yuv420p\n  Stream #0:1: Audio: ac3, 48000") == ("hevc", "ac3"))
        #expect(VideoPreview.parseCodecs("  Stream #0:0: Audio: mp3") == ("", "mp3"))
        #expect(VideoPreview.parseCodecs("Video: h264 (outside a stream line)") == ("", ""))
        #expect(VideoPreview.parseCodecs("") == ("", ""))
    }

    private let input = URL(fileURLWithPath: "/tmp/in.mkv"), output = URL(fileURLWithPath: "/tmp/out/index.m3u8")

    @Test func copiesH264AndAAC() {
        let a = VideoPreview.streamArguments(input: input, codecs: ("h264", "aac"), output: output)
        #expect(a.contains(subsequence: ["-c:v", "copy"]) && a.contains(subsequence: ["-c:a", "copy"]))
        #expect(!a.contains("h264_videotoolbox") && !a.contains("aac_at"))
        #expect(a.contains(subsequence: ["-nostdin", "-i", "file:/tmp/in.mkv"]))
        #expect(a.last == "/tmp/out/index.m3u8")
        #expect(a.contains(subsequence: ["-f", "hls"]) && a.contains(subsequence: ["-hls_segment_type", "fmp4"]))
        #expect(a.contains(subsequence: ["-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]))
    }

    @Test func copiesHEVCTaggedForApple() {
        let a = VideoPreview.streamArguments(input: input, codecs: ("hevc", "opus"), output: output)
        #expect(a.contains(subsequence: ["-c:v", "copy", "-tag:v", "hvc1"]))
        #expect(a.contains(subsequence: ["-c:a", "aac_at", "-b:a", "192k", "-ac", "2"]))
    }

    @Test func convertsEverythingElse() {
        for codecs in [("", ""), ("mpeg4", "mp3"), ("vp9", "aac"), ("H264", "AAC")] {
            let a = VideoPreview.streamArguments(input: input, codecs: codecs, output: output)
            #expect(a.contains(subsequence: ["-c:v", "h264_videotoolbox"]), "\(codecs)")
            #expect(a.contains(subsequence: ["-pix_fmt", "yuv420p"]))
            #expect(a.contains("scale='min(1920,iw)':-2"))
        }
    }

    @Test func inputNamesAreReadLiterally() {
        // A file named like an ffmpeg protocol or option stays a plain file path, one argument.
        for name in ["concat:a.mkv|b.mkv", "-y", "pipe:0", "http://x", "a b.mkv", "$(id).mkv"] {
            let u = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
            let a = VideoPreview.streamArguments(input: u, codecs: ("", ""), output: output)
            let i = a.firstIndex(of: "-i")!
            #expect(a[i + 1] == "file:" + u.path, "\(name)")
            #expect(a.filter { $0.contains(name) }.count == 1)
        }
    }
}

private extension Array where Element == String {
    func contains(subsequence s: [String]) -> Bool {
        guard s.count <= count else { return false }
        return (0...(count - s.count)).contains { Array(self[$0..<($0 + s.count)]) == s }
    }
}

/// The ffmpeg to test with: the one scripts/build-ffmpeg.sh builds, else one on PATH. CI's unit tests have neither.
let testFFmpeg: String? = {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let built = repo.appendingPathComponent("build/ffmpeg/ffmpeg").path
    if FileManager.default.isExecutableFile(atPath: built) { return built }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"] {
        let p = "\(dir)/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}()

/// Probing and streaming with a real ffmpeg on tiny generated videos. Streams go to a scratch folder.
@Suite(.serialized, .enabled(if: testFFmpeg != nil, "needs ffmpeg (build/ffmpeg/ffmpeg or on PATH)"))
final class VideoPreviewStreamTests {
    let scratch: Scratch
    let streams: URL

    init() throws {
        scratch = try Scratch()
        streams = try scratch.folder("streams")
        VideoPreview.testFFmpeg = testFFmpeg
        VideoPreview.testRoot = streams
    }

    deinit {
        VideoPreview.testFFmpeg = nil
        VideoPreview.testRoot = nil
    }

    /// A 1 s test picture (and tone) made by ffmpeg.
    func video(_ name: String, _ codecArgs: [String], audio: [String]? = nil) throws -> URL {
        let out = scratch.path(name)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10"]
        if audio != nil { args += ["-f", "lavfi", "-i", "sine=duration=1"] }
        args += codecArgs + (audio ?? ["-an"]) + ["-y", out.path]
        let r = try Shell.run(testFFmpeg!, args, timeout: 30)
        try #require(r.status == 0, "ffmpeg: \(r.err)")
        return out
    }

    // MARK: Probing

    @Test func probesH264InMKVAsCopyable() throws {
        let v = try video("x264 audio.mkv", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"])
        let info = VideoPreview.probe(v)
        #expect(info.codecs == ("h264", "aac"))
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
    }

    @Test func probesAVIAsConvertOnly() throws {
        // AVI can't carry a copied stream: the codecs come back empty so it is converted.
        let v = try video("mpeg4.avi", ["-c:v", "mpeg4"])
        let info = VideoPreview.probe(v)
        #expect(info.codecs == ("", ""))
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
        let h264avi = try video("x264.avi", ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
        #expect(VideoPreview.probe(h264avi).codecs == ("", ""))
    }

    @Test func probesNamesThatLookLikeProtocols() throws {
        let v = try video("concat:x.mkv", ["-c:v", "mjpeg"])
        let info = VideoPreview.probe(v)
        #expect(info.codecs.video == "mjpeg")
        #expect(info.duration != nil)
    }

    @Test func probingNonVideoGivesNothing() throws {
        let f = try scratch.file("text.mkv", "not a video")
        let info = VideoPreview.probe(f)
        #expect(info.codecs == ("", ""))
        #expect(info.duration == nil)
        #expect(VideoPreview.probe(scratch.path("missing.mkv")).duration == nil)
    }

    // MARK: Streaming

    /// `playableURL`, waiting for its answer (nil after 30 s, so a regression fails instead of hanging).
    func playable(_ p: VideoPreview, _ url: URL, owner: AnyObject) async -> URL? {
        await withCheckedContinuation { c in
            let once = Once()
            DispatchQueue.main.async { p.playableURL(for: url, owner: owner) { u in if once.claim() { c.resume(returning: u) } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if once.claim() { c.resume(returning: nil) } }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    func fetch(_ url: URL) async throws -> (Int, Data) {
        let (data, resp) = try await URLSession.shared.data(from: url)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Waits up to 15 s for `condition` (slow when the machine is busy).
    func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<300 { if condition() { return true }; usleep(50_000) }
        return condition()
    }

    func sessionFolders() -> [URL] {
        let mine = streams.appendingPathComponent(String(getpid()))
        return ((try? FileManager.default.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil)) ?? [])
    }

    func ffmpegRunning(on input: URL) -> Bool {
        (try? Shell.run("/usr/bin/pgrep", ["-f", input.path]))?.status == 0
    }

    @Test(arguments: [("mpeg4.avi", ["-c:v", "mpeg4"]), ("mjpeg.avi", ["-c:v", "mjpeg"]),
                      ("x264.mkv", ["-c:v", "libx264", "-pix_fmt", "yuv420p"]), ("x264 in.avi", ["-c:v", "libx264", "-pix_fmt", "yuv420p"])])
    func streamsOverLocalHTTP(name: String, codec: [String]) async throws {
        let v = try video(name, codec, audio: ["-c:a", "aac"])
        let p = VideoPreview()
        let owner = NSObject()
        defer { p.stop(); p.server.stop() }
        let url = try #require(await playable(p, v, owner: owner))
        #expect(url.scheme == "http" && url.host == "127.0.0.1" && url.lastPathComponent == "index.m3u8")
        let (status, list) = try await fetch(url)
        #expect(status == 200)
        let playlist = String(decoding: list, as: UTF8.self)
        #expect(playlist.hasPrefix("#EXTM3U"))
        // The init segment and the first media segment are served too.
        let seg = try #require(playlist.split(separator: "\n").first { $0.hasSuffix(".m4s") })
        let (segStatus, segData) = try await fetch(url.deletingLastPathComponent().appendingPathComponent(String(seg)))
        #expect(segStatus == 200 && !segData.isEmpty)
        // The duration is known once streaming has started.
        await MainActor.run { #expect(abs((p.streamDuration ?? 0) - 1) < 0.5) }
        // Without the secret, the same file isn't served.
        var noSecret = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        noSecret.path = "/" + url.pathComponents.dropFirst(2).joined(separator: "/")
        #expect(try await fetch(noSecret.url!).0 == 404)
    }

    @Test func filesAVFoundationPlaysAreReturnedAsTheyAre() async throws {
        let v = try video("plain.mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        #expect(await playable(p, v, owner: NSObject()) == v)
        #expect(sessionFolders().isEmpty)
    }

    @Test func onlyTheOwnerStopsTheStream() async throws {
        let v = try video("owned.avi", ["-c:v", "mpeg4"])
        let p = VideoPreview()
        let owner = NSObject(), other = NSObject()
        defer { p.stop(); p.server.stop() }
        let url = try #require(await playable(p, v, owner: owner))
        #expect(sessionFolders().count == 1)
        await MainActor.run { p.stop(for: other) }
        #expect(try await fetch(url).0 == 200)
        #expect(sessionFolders().count == 1)
        await MainActor.run { p.stop(for: owner) }
        // ffmpeg is ended and its folder removed once it has exited.
        #expect(eventually { sessionFolders().isEmpty })
        #expect(eventually { !ffmpegRunning(on: v) })
        #expect(try await fetch(url).0 == 404)
    }

    @Test func aNewerRequestWins() async throws {
        let first = try video("first.avi", ["-c:v", "mpeg4"])
        let second = try video("second.avi", ["-c:v", "mpeg4"])
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let lock = NSLock()
        var firstAnswered = false
        await MainActor.run {
            p.playableURL(for: first, owner: NSObject()) { _ in lock.lock(); firstAnswered = true; lock.unlock() }
        }
        let url = try #require(await playable(p, second, owner: NSObject()))
        #expect(url.lastPathComponent == "index.m3u8")
        usleep(300_000)
        lock.lock(); defer { lock.unlock() }
        #expect(!firstAnswered)   // the older request never calls back
        #expect(eventually { !ffmpegRunning(on: first) })
        #expect(eventually { sessionFolders().count == 1 })
    }

    @Test func unplayableFilesGiveNil() async throws {
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let junk = try scratch.file("junk.mkv", String(repeating: "x", count: 10_000))
        #expect(await playable(p, junk, owner: NSObject()) == nil)
        #expect(await playable(p, scratch.path("missing.avi"), owner: NSObject()) == nil)
    }

    @Test func withoutFFmpegNothingStreams() async throws {
        let v = try video("noff.avi", ["-c:v", "mpeg4"])
        VideoPreview.testFFmpeg = scratch.path("no-ffmpeg-here").path
        defer { VideoPreview.testFFmpeg = testFFmpeg }
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        #expect(await playable(p, v, owner: NSObject()) == nil)
        #expect(VideoPreview.probe(v).duration == nil)
    }

    @Test func cleanUpKeepsOtherLiveInstancesOnly() throws {
        let fm = FileManager.default
        // A live process (launchd: kill says EPERM), a finished one, an old layout, and this one's own.
        try scratch.file("streams/1/live/index.m3u8")
        let finished = try Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        finished.waitUntilExit()
        let dead = String(finished.processIdentifier)
        try scratch.file("streams/\(dead)/dead/index.m3u8")
        try scratch.file("streams/old-session/index.m3u8")
        try scratch.file("streams/\(getpid())/mine/index.m3u8")
        VideoPreview().cleanUp()
        #expect(fm.fileExists(atPath: streams.appendingPathComponent("1/live").path))
        #expect(!fm.fileExists(atPath: streams.appendingPathComponent(dead).path))
        #expect(!fm.fileExists(atPath: streams.appendingPathComponent("old-session").path))
        #expect(!fm.fileExists(atPath: streams.appendingPathComponent(String(getpid())).path))
    }
}
