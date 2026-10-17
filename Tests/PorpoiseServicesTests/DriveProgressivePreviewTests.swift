import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveProgressivePreviewTests {
    private func fixture(_ scratch: Scratch) throws -> URL {
        return try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": [
                    [
                        "id": "image", "name": "image.png", "mimeType": "image/png", "size": "4096", "version": "1",
                        "thumbnailLink": "{base}/thumbnail/image", "hasThumbnail": true, "capabilities": ["canDownload": true],
                    ]
                ],
                "generatedMedia": ["image": 4096],
            ])
    }

    @Test func firstThumbnailThenFullAndWarmViewMakesNoRequest() async throws {
        let scratch = try Scratch(), server = try FakeDriveServer(fixture: fixture(scratch), latencyMS: 300)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("image")
        var paints: [URL] = [], firstTime: TimeInterval?
        let start = Date()
        let full = try await client.progressivePreview(file) { url in
            if firstTime == nil { firstTime = Date().timeIntervalSince(start) }
            paints.append(url)
        }
        #expect(paints.count == 2 && paints.last == full && paints.first != full)
        let elapsed = try #require(firstTime)
        print("PREVIEW_FIRST_IMAGE seconds=\(elapsed) latency=300ms")
        if ProcessInfo.processInfo.environment["PORPOISE_PREVIEW_BENCHMARK"] == "1" { #expect(elapsed < 0.55) }
        let before = try await server.stats()
        #expect((before["requests"] as? [String])?.contains { $0.contains("/thumbnail/image=s1600") } == true)
        var warm: [URL] = []
        #expect(try await client.progressivePreview(file) { warm.append($0) } == full)
        #expect(warm == [full])
        // Warm: nothing more was asked of the server.
        let after = try await server.stats()
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        await client.clearCaches()
    }

    @Test func textPrefixShowsBeforeWholeFile() async throws {
        let scratch = try Scratch(), url = try fixture(scratch)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try #require(json["files"] as? [[String: Any]])
        files[0]["name"] = "code.swift"; files[0]["mimeType"] = "text/plain"; files[0]["size"] = "131072"
        files[0].removeValue(forKey: "thumbnailLink"); files[0]["hasThumbnail"] = false
        json["files"] = files; json["generatedMedia"] = ["image": 131072]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let server = try FakeDriveServer(fixture: url, latencyMS: 300)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("image")
        var sizes: [Int] = []
        _ = try await client.progressivePreview(file) { sizes.append(try Data(contentsOf: $0).count) }
        #expect(sizes == [65536, 131072])
        await client.clearCaches()
    }

    @Test func changingSelectionAfterThumbnailCancelsFullDownload() async throws {
        let scratch = try Scratch(), server = try FakeDriveServer(fixture: fixture(scratch), latencyMS: 300)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("image")
        let task = Task {
            try await client.progressivePreview(file) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let json = try await server.stats()
        #expect(json["mediaBytes"] as? Int == 0)
        await client.clearCaches()
    }
}
