import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import os

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
        #expect(VideoPreview.parseDuration("Duration: 00:00:01.5") == 1.5)  // no comma: to the end
        #expect(VideoPreview.parseDuration("Duration: 123:00:00.00,") == 442_800.0)
        for bad in [
            "Duration: N/A, start: 0", "Duration: 00:01, x", "Duration: 1:2:3:4,", "Duration: aa:bb:cc,", "no duration here", "",
            "Duration: ,",
        ] {
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
            #expect(a.contains(subsequence: ["-allow_sw", "1"]))
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

/// The ffmpeg under test: the one Porpoise ships (scripts/build-ffmpeg.sh), else one on PATH. CI builds Porpoise's.
let testFFmpeg: String? = {
    // scripts/ci-like.sh gives this process a cooperative pool of one thread; ffmpeg, which inherits the setting,
    // crashes with it in its sandbox. Its own pool is not what the run constrains (the variable was read at launch;
    // `cooperativePoolIsStrict` keeps what it said).
    if cooperativePoolIsStrict { unsetenv("LIBDISPATCH_COOPERATIVE_POOL_STRICT") }
    let built = repoRoot.appendingPathComponent("build/ffmpeg/ffmpeg").path
    if FileManager.default.isExecutableFile(atPath: built) { return built }
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return dirs.map { "\($0)/ffmpeg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}()

private let repoRoot = TestPaths.repo

/// One-second test clips (160×120, a test picture and a tone), one per codec and container the tests need.
private let clips = TestPaths.fixtures.appendingPathComponent("Videos")

/// Probing and streaming with a real ffmpeg on tiny generated videos. Streams go to a scratch folder.
@Suite(.serialized, .enabled(if: testFFmpeg != nil, "needs ffmpeg: scripts/build-ffmpeg.sh, or one on PATH"))
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

    /// The clip `fixture` (in Fixtures/Videos) as a file named `name` in the scratch folder.
    func video(_ name: String, _ fixture: String) throws -> URL {
        let out = scratch.path(name)
        try FileManager.default.copyItem(at: clips.appendingPathComponent(fixture), to: out)
        return out
    }

    // MARK: Probing

    @Test func probesH264InMKVAsCopyable() throws {
        let v = try video("x264 audio.mkv", "h264-aac.mkv")
        let info = VideoPreview.probe(v)
        #expect(info.codecs == ("h264", "aac"))
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
    }

    @Test func probesVideoThroughDirectorySymlinks() throws {
        _ = try scratch.folder("original")
        let file = try video("original/video.mkv", "h264-aac.mkv")
        try scratch.symlink("alias", to: file.deletingLastPathComponent().path)
        let info = VideoPreview.probe(scratch.path("alias/video.mkv"))
        #expect(info.codecs == ("h264", "aac"))
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
    }

    @Test func probesAVIAsConvertOnly() throws {
        // AVI can't carry a copied stream: the codecs come back empty so it is converted.
        let v = try video("mpeg4.avi", "mpeg4.avi")
        let info = VideoPreview.probe(v)
        #expect(info.codecs == ("", ""))
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
        let h264avi = try video("x264.avi", "h264.avi")
        #expect(VideoPreview.probe(h264avi).codecs == ("", ""))
    }

    @Test func probesNamesThatLookLikeProtocols() throws {
        let v = try video("concat:x.mkv", "mjpeg.mkv")
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

    /// Exercise the VM/no-hardware path even on a Mac with a hardware encoder, without widening its sandbox.
    @Test func softwareEncodingStaysInsideSandbox() throws {
        let input = try video("software.avi", "mpeg4-aac.avi")
        let output = try scratch.folder("software-output")
        let playlist = output.appendingPathComponent("index.m3u8")
        var arguments = VideoPreview.streamArguments(input: input, codecs: ("", ""), output: playlist)
        arguments.insert(contentsOf: ["-require_sw", "1"], at: arguments.count - 1)
        let result = try Shell.run(
            "/usr/bin/sandbox-exec",
            VideoPreview.sandboxArguments(
                executable: try #require(testFFmpeg), input: input, output: output, arguments: arguments), timeout: 120)
        #expect(result.status == 0, "\(result.err)")
        let contents = try String(contentsOf: playlist, encoding: .utf8)
        #expect(contents.contains(".m4s"))
        #expect(contents.contains("#EXT-X-ENDLIST"))
    }

    /// `playableURL`, waiting for its answer. It fails after 60 s instead of hanging: beyond the preview's own worst
    /// case (probe, then copy, then convert, 10 s each).
    @MainActor func playable(_ p: VideoPreview, _ url: URL, owner: AnyObject) async throws -> URL? {
        try await awaitCallback(timeout: 60) { c in p.playableURL(for: url, owner: owner) { c.resume(returning: $0) } }
    }

    func fetch(_ url: URL) async throws -> (Int, Data) {
        let (data, resp) = try await URLSession.shared.data(from: url)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func sessionFolders() -> [URL] {
        let mine = streams.appendingPathComponent(String(getpid()))
        return ((try? FileManager.default.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil)) ?? [])
    }

    func ffmpegRunning(on input: URL) -> Bool {
        (try? Shell.run("/usr/bin/pgrep", ["-f", input.path]))?.status == 0
    }

    @Test(arguments: [
        ("mpeg4.avi", "mpeg4-aac.avi"), ("mjpeg.avi", "mjpeg-aac.avi"), ("x264.mkv", "h264-aac.mkv"), ("x264 in.avi", "h264-aac.avi"),
    ])
    func streamsOverLocalHTTP(name: String, fixture: String) async throws {
        let v = try video(name, fixture)
        let p = VideoPreview()
        let owner = NSObject()
        defer { p.stop(); p.server.stop() }
        let url = try #require(try await playable(p, v, owner: owner))
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
        let v = try video("plain.mp4", "h264.mp4")
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        #expect(try await playable(p, v, owner: NSObject()) == v)
        #expect(sessionFolders().isEmpty)
    }

    @Test func onlyTheOwnerStopsTheStream() async throws {
        let v = try video("owned.avi", "mpeg4.avi")
        let p = VideoPreview()
        let owner = NSObject(), other = NSObject()
        defer { p.stop(); p.server.stop() }
        let url = try #require(try await playable(p, v, owner: owner))
        #expect(sessionFolders().count == 1)
        await MainActor.run { p.stop(for: other) }
        #expect(try await fetch(url).0 == 200)
        #expect(sessionFolders().count == 1)
        await MainActor.run { p.stop(for: owner) }
        // ffmpeg is ended and its folder removed once it has exited.
        #expect(
            await poll { sessionFolders().isEmpty },
            "left: \(sessionFolders().map { "\($0.lastPathComponent): \((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [])" })")
        #expect(await poll { !ffmpegRunning(on: v) })
        #expect(try await fetch(url).0 == 404)
    }

    @Test func aNewerRequestWins() async throws {
        let first = try video("first.avi", "mpeg4.avi")
        let second = try video("second.avi", "mpeg4.avi")
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let firstAnswered = OSAllocatedUnfairLock(initialState: false)
        await MainActor.run {
            p.playableURL(for: first, owner: NSObject()) { _ in firstAnswered.withLock { $0 = true } }
        }
        let url = try #require(try await playable(p, second, owner: NSObject()))
        #expect(url.lastPathComponent == "index.m3u8")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!firstAnswered.withLock { $0 })  // the older request never calls back
        #expect(await poll { !ffmpegRunning(on: first) })
        #expect(await poll { sessionFolders().count == 1 })
    }

    @Test func unplayableFilesGiveNil() async throws {
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let junk = try scratch.file("junk.mkv", String(repeating: "x", count: 10_000))
        #expect(try await playable(p, junk, owner: NSObject()) == nil)
        #expect(try await playable(p, scratch.path("missing.avi"), owner: NSObject()) == nil)
    }

    @Test func withoutFFmpegNothingStreams() async throws {
        let v = try video("noff.avi", "mpeg4.avi")
        VideoPreview.testFFmpeg = scratch.path("no-ffmpeg-here").path
        defer { VideoPreview.testFFmpeg = testFFmpeg }
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        #expect(try await playable(p, v, owner: NSObject()) == nil)
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

/// A stream's folder goes once nothing writes into it, in whichever order ffmpeg starts and the stream is stopped.
struct StreamSessionTests {
    private func writer(into dir: URL) throws -> Process {
        // Stands in for ffmpeg: keeps writing into the folder, creating it again if it's gone.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while :; do mkdir -p \"$0\" && date > \"$0/seg.m4s\"; sleep 0.05; done", dir.path]
        try p.run()
        return p
    }

    private func gone(_ url: URL) async -> Bool {
        _ = await poll { !FileManager.default.fileExists(atPath: url.path) }
        // Still gone a moment later: nothing wrote it back.
        try? await Task.sleep(for: .milliseconds(300))
        return !FileManager.default.fileExists(atPath: url.path)
    }

    @Test func stoppedAfterFFmpegStarted() async throws {
        let s = try Scratch()
        let dir = try s.folder("session")
        let session = StreamSession(dir: dir)
        let p = try writer(into: dir)
        #expect(session.attach(p))
        session.stop()
        #expect(await gone(dir))
        #expect(await poll { !p.isRunning })
    }

    /// The race that left folders behind: the stop comes before ffmpeg is handed to the session.
    @Test func stoppedBeforeFFmpegWasHandedOver() async throws {
        let s = try Scratch()
        let dir = try s.folder("session")
        let session = StreamSession(dir: dir)
        session.stop()
        let p = try writer(into: dir)
        #expect(!session.attach(p))
        #expect(await gone(dir))
        await offThePool { p.waitUntilExit() }
    }
}
