import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// More of VideoPreviewStreamTests: in its suite (serialized, as they all change `VideoPreview.testFFmpeg` and
/// `testRoot`), with a stand-in ffmpeg where the real one can't be made to fail on cue.
extension VideoPreviewStreamTests {
    /// Copying the streams fails (as H.264 from some containers does): the stream is converted instead.
    @Test func aFailedCopyIsConvertedInstead() async throws {
        let fake = try scratch.file(
            "fake-ffmpeg",
            """
            #!/bin/sh
            for a; do last=$a; done
            case "$*" in
              *"-f hls"*) ;;
              *) printf "Input #0, matroska,webm, from 'x':\\n  Duration: 00:00:02.00, start: 0\\n" >&2
                 printf "  Stream #0:0: Video: h264 (High)\\n  Stream #0:1: Audio: aac (LC)\\n" >&2
                 exit 1 ;;
            esac
            echo "$*" >> \(RemoteParsing.quote(scratch.path("runs").path))
            case "$*" in *"-c:v copy"*) exit 1 ;; esac
            printf '#EXTM3U\\n#EXTINF:2,\\nindex0.m4s\\n' > "$last"
            echo segment > "$(dirname "$last")/index0.m4s"

            """)
        chmod(fake.path, 0o755)
        VideoPreview.testFFmpeg = fake.path
        defer { VideoPreview.testFFmpeg = testFFmpeg }
        let v = try scratch.file("copy fails.mkv", String(repeating: "x", count: 4096))
        let p = VideoPreview()
        defer { p.stop(); p.server.stop() }
        let url = try #require(await playable(p, v, owner: NSObject()))
        #expect(url.lastPathComponent == "index.m3u8")
        let runs = (scratch.read("runs") ?? "").split(separator: "\n")
        #expect(runs.count == 2)
        #expect(runs.first?.contains("-c:v copy") == true && runs.last?.contains("h264_videotoolbox") == true)
        await MainActor.run { #expect(p.streamDuration == 2) }
        #expect(try await fetch(url).0 == 200)
    }

    @Test func cleaningUpWithoutAStreamsFolderDoesNothing() {
        VideoPreview.testRoot = scratch.path("never-made")
        defer { VideoPreview.testRoot = streams }
        VideoPreview().cleanUp()
        #expect(!FileManager.default.fileExists(atPath: scratch.path("never-made").path))
    }

    /// Outside tests: the ffmpeg in the app bundle, else one on PATH (never something that can't run).
    @Test func theAppsOwnFFmpegIsFound() {
        VideoPreview.testFFmpeg = nil
        defer { VideoPreview.testFFmpeg = testFFmpeg }
        if let f = VideoPreview.ffmpeg { #expect(FileManager.default.isExecutableFile(atPath: f)) }
    }
}
