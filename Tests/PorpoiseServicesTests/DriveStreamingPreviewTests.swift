import AVFoundation
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveStreamingPreviewTests {
    private func fixture(_ scratch: Scratch, media: URL? = nil) throws -> URL {
        let url = scratch.url.appendingPathComponent("fixture.json")
        var json: [String: Any] = [
            "files": [
                [
                    "id": "movie", "name": "movie.mp4", "mimeType": "video/mp4", "size": String(64 << 20),
                    "version": "1", "headRevisionId": "revision-1", "capabilities": ["canDownload": true],
                ]
            ],
            "generatedMedia": ["movie": 64 << 20],
        ]
        if let media { json["mediaFiles"] = ["movie": media.path] }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    @Test func rangesAreBoundedSecretAndStopCancels() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch), latencyMS: 300, connectionMbps: 40)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("movie")
        let stream = try client.streamingPreview(file)
        #expect(stream.url.host == "127.0.0.1")
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=123-456", forHTTPHeaderField: "Range")
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(start)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 123-456/67108864")
        #expect(data == Data(repeating: 120, count: 334))
        print("STREAM_FIRST_RANGE seconds=\(elapsed) latency=300ms bytes=\(data.count)")
        if ProcessInfo.processInfo.environment["PORPOISE_PREVIEW_BENCHMARK"] == "1" { #expect(elapsed < 0.55) }
        let wrong = stream.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wrong/media")
        #expect((try await URLSession.shared.data(from: wrong).1 as? HTTPURLResponse)?.statusCode == 404)
        request.httpMethod = "HEAD"
        #expect(try await URLSession.shared.data(for: request).0.isEmpty)
        #expect(try await server.stats()["mediaBytes"] as? Int == 334)
        #expect(try await (server.stats()["requests"] as? [String])?.contains { $0.contains("/revisions/revision-1?alt=media") } == true)
        let load = Task { try await URLSession.shared.data(from: stream.url) }
        for _ in 0..<100 {
            if try await (server.stats()["ranges"] as? [String])?.count ?? 0 > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        stream.stop()
        await #expect(throws: (any Error).self) { try await load.value }
        let before = try await server.stats()["mediaBytes"] as? Int
        try await Task.sleep(for: .milliseconds(400))
        let after = try await server.stats()["mediaBytes"] as? Int
        #expect((after ?? 0) - (before ?? 0) <= 1 << 20)
    }

    @Test func rangeParserRejectsMalformedAndHandlesSuffixAndOpenEnd() throws {
        #expect(try LocalFileServer.byteRange(nil, size: 100) == 0..<100)
        #expect(try LocalFileServer.byteRange("bytes=10-", size: 100) == 10..<100)
        #expect(try LocalFileServer.byteRange("bytes=-10", size: 100) == 90..<100)
        #expect(try LocalFileServer.byteRange("bytes=50-999", size: 100) == 50..<100)
        for value in ["bytes=100-", "bytes=-0", "bytes=4-3", "bytes=0-1,4-5", "items=0-1", "bytes=a-b", "bytes=1-2-3"] {
            #expect(throws: DriveError.invalidResponse) { try LocalFileServer.byteRange(value, size: 100) }
        }
    }

    @Test(.enabled(if: testFFmpeg != nil)) @MainActor
    func playerStartsBeforeTenPercentFetched() async throws {
        let scratch = try Scratch(), media = scratch.url.appendingPathComponent("movie.mp4")
        let ffmpeg = try #require(testFFmpeg)
        let clip = TestPaths.fixtures.appendingPathComponent("Videos/h264-aac.mkv")
        let result = try Shell.run(
            ffmpeg,
            [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-stream_loop", "119", "-i", clip.path,
                "-t", "120", "-map", "0:v:0", "-c:v", "copy", "-an", "-movflags", "+faststart", media.path,
            ], timeout: 30)
        try #require(result.status == 0, "\(result.err)")
        let handle = try FileHandle(forWritingTo: media)
        let size = try handle.seekToEnd()
        let padding = UInt32((64 << 20) - size).bigEndian
        try withUnsafeBytes(of: padding) { try handle.write(contentsOf: $0) }
        try handle.write(contentsOf: Data("free".utf8))
        try handle.truncate(atOffset: 64 << 20); try handle.close()
        let server = try FakeDriveServer(fixture: fixture(scratch, media: media), latencyMS: 300, connectionMbps: 10)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let stream = try client.streamingPreview(try await client.file("movie"))
        defer { stream.stop() }
        let item = AVPlayerItem(url: stream.url)
        item.preferredForwardBufferDuration = 0.5
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let start = Date()
        player.play()
        for _ in 0..<400 where player.currentTime().seconds < 0.05 && item.status != .failed {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(item.status != .failed, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 0.05)
        let bytes = try #require(try await server.stats()["mediaBytes"] as? Int)
        print("STREAM_PLAYING seconds=\(Date().timeIntervalSince(start)) bytes=\(bytes) total=67108864 fraction=\(Double(bytes) / Double(64 << 20))")
        #expect(bytes < (64 << 20) / 10)
    }
}
