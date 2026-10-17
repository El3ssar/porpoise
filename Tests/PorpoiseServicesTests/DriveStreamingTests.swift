import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveStreamingTests {
    private func fixture(_ scratch: Scratch, size: Int, checksum: String? = nil) throws -> URL {
        let url = scratch.url.appendingPathComponent("fixture.json")
        let digest = checksum ?? Insecure.MD5.hash(data: Data(repeating: 120, count: size)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: [
            "files": [
                [
                    "id": "movie", "name": "movie.mp4", "mimeType": "video/mp4",
                    "size": String(size), "version": "1", "headRevisionId": "revision-1", "md5Checksum": digest,
                    "capabilities": ["canDownload": true],
                ]
            ], "generatedMedia": ["movie": size],
        ]).write(to: url)
        return url
    }

    @Test func disconnectedStreamResumesFromDurableCheckpoint() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 24 << 20))
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("movie"), operation = UUID()
        try await DriveMutationTests().control(server, ["dropDownloadAfterBytes": 12 << 20])
        await #expect(throws: (any Error).self) { try await client.downloadToStaging(file, operationID: operation) }
        let record = try #require(try client.mutationJournal.load(operation))
        #expect(record.offset >= 8 << 20 && record.offset < 12 << 20)
        let result = try await client.downloadToStaging(file, operationID: operation)
        #expect(try DriveClient.md5(result.url) == file.md5Checksum)
        let stats = try await URLSession.shared.data(from: server.base.appendingPathComponent("__stats")).0
        let requests = try #require((try JSONSerialization.jsonObject(with: stats) as? [String: Any])?["requests"] as? [String])
        #expect(requests.filter { $0.contains("alt=media") }.count == 2)
    }

    @Test func changedRevisionAndChecksumFailClosed() async throws {
        let scratch = try Scratch(), checks = DriveMutationTests()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 2 << 20))
        let client = try checks.client(server, folder: scratch.url.appendingPathComponent("journal"))
        try await checks.control(server, ["changeRevisionDuringDownload": true])
        let operation = UUID()
        await #expect(throws: DriveMutationError.sourceChanged) { try await client.downloadToStaging(client.file("movie"), operationID: operation) }
        #expect(try client.mutationJournal.load(operation)?.phase != .done)
        let badScratch = try Scratch()
        let bad = try FakeDriveServer(fixture: fixture(badScratch, size: 2 << 20, checksum: "wrong"))
        let badClient = try checks.client(bad, folder: badScratch.url.appendingPathComponent("journal"))
        await #expect(throws: DriveError.invalidResponse) { try await badClient.downloadToStaging(badClient.file("movie")) }
    }

    @Test func videoAboveOldCacheLimitAndWarmCacheNeedsNoRequest() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 300 << 20))
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("movie")
        let url = try await client.preview(file)
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 300 << 20)
        server.stop()
        #expect(try await client.cachedPreview(file) == url)
        #expect(try await client.preview(file) == url)
        await client.clearCaches()
    }
    @Test @MainActor func remoteOpenLaunchesAfterActivityAndCachedOpenDoesNotWaitForNetwork() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 8 << 20), bandwidthMbps: 100)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let operations = FileOperationsController()
        operations.history = OperationHistory(file: scratch.url.appendingPathComponent("history"))
        provider.openingOperations = operations
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let item = try await client.file("movie").fileItem(accountID: client.accountID)
        var opened: [URL] = []
        RemoteOpener.open(item, using: { opened.append($0) })
        var sawProgress = false
        for _ in 0..<500 where opened.isEmpty {
            if let activity = operations.activities.last, activity.state == .running, (activity.progress?.doneBytes ?? 0) > 0 {
                sawProgress = true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawProgress && opened.count == 1 && operations.activities.last?.state == .completed)
        #expect(operations.activities.last?.title == "Opening “movie.mp4”")
        server.stop()
        RemoteOpener.open(item, using: { opened.append($0) })
        for _ in 0..<20 where opened.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(opened.count == 2 && opened.first == opened.last && operations.activities.count == 1)
        await client.clearCaches()
    }

}
