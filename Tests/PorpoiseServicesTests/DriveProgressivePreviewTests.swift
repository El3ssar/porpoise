import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveProgressivePreviewTests {
    private func fixture(_ scratch: Scratch) throws -> URL {
        let url = scratch.url.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: [
            "files": [
                [
                    "id": "image", "name": "image.png", "mimeType": "image/png", "size": "4096", "version": "1",
                    "thumbnailLink": "{base}/thumbnail/image", "hasThumbnail": true, "capabilities": ["canDownload": true],
                ]
            ],
            "generatedMedia": ["image": 4096],
        ]).write(to: url)
        return url
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
        #expect(elapsed < 0.55)
        let stats = server.base.appendingPathComponent("__stats")
        let before = try await URLSession.shared.data(from: stats).0
        var warm: [URL] = []
        #expect(try await client.progressivePreview(file) { warm.append($0) } == full)
        #expect(warm == [full])
        let after = try await URLSession.shared.data(from: stats).0
        #expect(before == after)
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
        let data = try await URLSession.shared.data(from: server.base.appendingPathComponent("__stats")).0
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mediaBytes"] as? Int == 0)
        await client.clearCaches()
    }
}
