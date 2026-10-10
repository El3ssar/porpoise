import AVFoundation
import Foundation

/// Video for the Information panel in any format and size. AVFoundation plays what it can directly; anything else
/// (MKV, WebM, AVI, WMV, FLV…) goes through ffmpeg into a live HLS stream, repackaged (fast, no quality loss) when the
/// codecs allow it, or converted with the hardware encoder otherwise, served to AVPlayer from 127.0.0.1.
public final class VideoPreview {
    public static let shared = VideoPreview()

    static let videoExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "f4v", "ogv", "ogg", "mpg", "mpeg", "m2v", "ts",
                                               "m2ts", "mts", "vob", "divx", "xvid", "3gp", "3g2", "rm", "rmvb", "asf", "mxf", "nut", "y4m"]
    public static func isVideoExtension(_ ext: String) -> Bool { videoExtensions.contains(ext.lowercased()) }

    /// The ffmpeg bundled in Contents/Helpers (built by scripts/build-ffmpeg.sh); a system one only as a fallback.
    public static var ffmpeg: String? {
        if let t = testFFmpeg { return t }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : Shell.which("ffmpeg")
    }

    /// Tests: the ffmpeg to use, and where streams go (instead of the user's Caches folder).
    nonisolated(unsafe) static var testFFmpeg: String?
    nonisolated(unsafe) static var testRoot: URL?

    /// How long to wait for the first HLS segment, and how often to look.
    private static let startupTimeout: TimeInterval = 10
    private static let pollInterval: useconds_t = 50_000
    private static let probeTimeout: TimeInterval = 10
    private static let playlistName = "index.m3u8"

    private var process: Process?
    private var sessionDir: URL?
    /// Bumped on every request/stop; background work for an older token gives up. Read off the main thread.
    private let tokenLock = NSLock()
    private var _token = 0
    private var token: Int {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }
    let server = LocalFileServer()

    /// Shared by every running Dolphin (a second window process, test instances): each keeps its streams
    /// in a folder named after its process id, so one instance never removes another one's stream.
    private static var sharedRoot: URL {
        if let t = testRoot { return t }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise/video-preview")
    }

    private var root: URL {
        let u = Self.sharedRoot.appendingPathComponent(String(getpid()))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The length of the file being streamed (a stream that is still being converted doesn't know it yet).
    public private(set) var streamDuration: Double?

    /// Who asked for the current stream: only they stop it (one window's panel mustn't end another's video).
    private weak var owner: AnyObject?

    /// Calls back on the main thread with a URL AVPlayer can play, or nil.
    public func playableURL(for url: URL, owner: AnyObject, done: @escaping (URL?) -> Void) {
        self.owner = owner
        token += 1
        let my = token
        let asset = AVURLAsset(url: url)
        Task {
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.load(.tracks)) ?? []
            await MainActor.run {
                guard my == self.token else { return }
                if playable && !tracks.isEmpty { done(url); return }
                self.startStream(url, token: my, done: done)
            }
        }
    }

    /// Stops the stream `owner` asked for (nothing if another panel has started one since).
    public func stop(for owner: AnyObject) {
        guard owner === self.owner else { return }
        stop()
    }

    /// Stops the current stream; its folder is removed once ffmpeg has exited (it may still be writing).
    public func stop() {
        token += 1
        let p = process, dir = sessionDir
        process = nil
        sessionDir = nil
        guard p != nil || dir != nil else { return }
        p?.terminate()
        DispatchQueue.global(qos: .utility).async {
            p?.waitUntilExit()
            if let d = dir { try? FileManager.default.removeItem(at: d) }
        }
    }

    /// Removes this instance's streams and leftovers of instances that are no longer running (folders
    /// of live processes stay; older layouts without a process folder are removed too).
    public func cleanUp() {
        stop()
        let fm = FileManager.default
        let me = getpid()
        for name in (try? fm.contentsOfDirectory(atPath: Self.sharedRoot.path)) ?? [] {
            if let pid = pid_t(name), pid != me, kill(pid, 0) == 0 || errno == EPERM { continue }
            try? fm.removeItem(at: Self.sharedRoot.appendingPathComponent(name))
        }
    }

    private func startStream(_ url: URL, token my: Int, done: @escaping (URL?) -> Void) {
        guard let ffmpeg = Self.ffmpeg, url.isFileURL else { done(nil); return }
        stop()
        token = my
        let dir = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir
        streamDuration = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let info = Self.probe(url)
            let playlist = dir.appendingPathComponent(Self.playlistName)
            /// Runs ffmpeg; true once the stream has its first part.
            func run(_ codecs: (video: String, audio: String)) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = Self.streamArguments(input: url, codecs: codecs, output: playlist)
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return false }
                DispatchQueue.main.async { if my == self.token { self.process = p } else { p.terminate() } }
                if self.waitForFirstSegment(playlist, process: p, token: my) { return true }
                // Too slow or failed: this ffmpeg must not keep writing into the folder the retry reuses.
                p.terminate()
                p.waitUntilExit()
                return false
            }
            var ok = run(info.codecs)
            // Copying the streams as they are can fail (H.264 in AVI, odd AAC): convert them instead.
            if !ok, my == self.token, info.codecs != ("", "") {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                ok = run(("", ""))
            }
            DispatchQueue.main.async {
                guard my == self.token else { return }
                self.streamDuration = info.duration
                guard ok, let base = self.server.start(root: self.root) else { done(nil); return }
                done(base.appendingPathComponent(dir.lastPathComponent).appendingPathComponent(Self.playlistName))
            }
        }
    }

    /// Ready once the playlist lists its first segment (or ffmpeg ended with a playlist written).
    private func waitForFirstSegment(_ playlist: URL, process p: Process, token my: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline, my == token {
            if let s = try? String(contentsOf: playlist, encoding: .utf8), s.contains(".m4s") { return true }
            if !p.isRunning { break }
            usleep(Self.pollInterval)
        }
        return my == token && FileManager.default.fileExists(atPath: playlist.path)
    }

    /// ffmpeg arguments: copy H.264/HEVC and AAC as they are, convert anything else with VideoToolbox.
    /// The input is given as "file:" so a name that looks like a protocol ("concat:…") is read literally.
    static func streamArguments(input: URL, codecs: (video: String, audio: String), output: URL) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", "file:" + input.path,
                    "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]
        switch codecs.video {
        case "h264": args += ["-c:v", "copy"]
        case "hevc": args += ["-c:v", "copy", "-tag:v", "hvc1"]
        default: args += ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p", "-vf", "scale='min(1920,iw)':-2"]
        }
        args += codecs.audio == "aac" ? ["-c:a", "copy"] : ["-c:a", "aac_at", "-b:a", "192k", "-ac", "2"]
        args += ["-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
                 "-hls_segment_type", "fmp4", "-hls_flags", "independent_segments", output.path]
        return args
    }

    /// Codecs and length, from ffmpeg's description of the file.
    /// Streams are only copied out of containers that carry what the copy needs (MKV/WebM, MP4/MOV); from AVI, MPEG,
    /// FLV and the like the copy can't be played, so their streams are converted (the codecs come back empty).
    static func probe(_ url: URL) -> (codecs: (video: String, audio: String), duration: Double?) {
        guard let ff = ffmpeg,
              let r = try? Shell.run(ff, ["-hide_banner", "-nostdin", "-i", "file:" + url.path], timeout: probeTimeout) else { return (("", ""), nil) }
        let copyable = parseContainer(r.err).contains { $0 == "matroska" || $0 == "webm" || $0 == "mov" || $0 == "mp4" }
        return (copyable ? parseCodecs(r.err) : ("", ""), parseDuration(r.err))
    }

    /// "Input #0, matroska,webm, from …" → ["matroska", "webm"].
    static func parseContainer(_ text: String) -> [String] {
        guard let r = text.range(of: "Input #0, ") else { return [] }
        return text[r.upperBound...].prefix { $0 != " " }.split(separator: ",").map(String.init)
    }

    /// "Duration: 00:34:40.56," → seconds.
    static func parseDuration(_ text: String) -> Double? {
        guard let r = text.range(of: "Duration: ") else { return nil }
        let parts = text[r.upperBound...].prefix { $0 != "," }.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func parseCodecs(_ text: String) -> (video: String, audio: String) {
        var v = "", a = ""
        for line in text.split(separator: "\n") where line.contains("Stream #") {
            for (kind, isVideo) in [("Video: ", true), ("Audio: ", false)] {
                guard let r = line.range(of: kind) else { continue }
                let name = line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if isVideo, v.isEmpty, !line.contains("attached pic") { v = String(name) }
                if !isVideo, a.isEmpty { a = String(name) }
            }
        }
        return (v, a)
    }
}
