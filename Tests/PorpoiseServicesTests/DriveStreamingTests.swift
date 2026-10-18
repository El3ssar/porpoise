import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveStreamingTests {
    private func fixture(_ scratch: Scratch, size: Int, checksum: String? = nil) throws -> URL {
        let digest = checksum ?? FakeDriveServer.generatedMediaMD5(size: size)
        return try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": [
                    [
                        "id": "movie", "name": "movie.mp4", "mimeType": "video/mp4",
                        "size": String(size), "version": "1", "headRevisionId": "revision-1", "md5Checksum": digest,
                        "capabilities": ["canDownload": true],
                    ]
                ], "generatedMedia": ["movie": size],
            ])
    }

    @Test func disconnectedStreamResumesFromDurableCheckpoint() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 24 << 20))
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("movie"), operation = UUID()
        try await server.control(["dropDownloadAfterBytes": 12 << 20])
        await #expect(throws: (any Error).self) { try await client.downloadToStaging(file, operationID: operation) }
        let record = try #require(try client.mutationJournal.load(operation))
        // The engine checkpoints after 8 MiB OR two seconds. A loaded runner may durably
        // checkpoint a smaller prefix before the connection drops; its bytes must still be exact.
        #expect(record.offset > 0 && record.offset <= 12 << 20)
        let partial = client.mutationJournal.folder.appendingPathComponent("Downloads").appendingPathComponent(operation.uuidString + ".part")
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value == record.offset)
        #expect(try Data(contentsOf: partial) == Data(repeating: 120, count: Int(record.offset)))
        let result = try await client.downloadToStaging(file, operationID: operation)
        #expect(try DriveClient.md5(result.url) == file.md5Checksum)
        let requests = try #require(try await server.stats()["requests"] as? [String])
        #expect(requests.filter { $0.contains("alt=media") }.count == 2)
    }

    @Test func changedRevisionAndChecksumFailClosed() async throws {
        let scratch = try Scratch(), checks = DriveMutationTests()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 2 << 20))
        let client = try checks.client(server, folder: scratch.url.appendingPathComponent("journal"))
        try await server.control(["changeRevisionDuringDownload": true])
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
        // The fake sends the first MiB and then waits, so the running transfer's progress is there to see.
        try await server.control(["pauseDownloadAfterBytes": 1 << 20])
        var opened: [URL] = []
        RemoteOpener.open(item, using: { opened.append($0) })
        let sawProgress = await eventually {
            guard let activity = operations.activities.last else { return false }
            return activity.state == .running && (activity.progress?.doneBytes ?? 0) > 0
        }
        #expect(opened.isEmpty)
        try await server.control(["resumeDownload": true])
        _ = await eventually { !opened.isEmpty }
        #expect(sawProgress && opened.count == 1 && operations.activities.last?.state == .completed)
        #expect(operations.activities.last?.title == "Opening “movie.mp4”")
        server.stop()
        RemoteOpener.open(item, using: { opened.append($0) })
        _ = await poll { opened.count == 2 }
        #expect(opened.count == 2 && opened.first == opened.last && operations.activities.count == 1)
        await client.clearCaches()
    }

    @Test @MainActor func unknownMetadataLookupIsAlreadyVisibleInActivity() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 4096), latencyMS: 200)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let operations = FileOperationsController()
        operations.history = OperationHistory(file: scratch.url.appendingPathComponent("history"))
        provider.openingOperations = operations
        let remote = DriveLocation(accountID: client.accountID, collection: .folder("movie")).url
        // The fake holds the metadata lookup until the test has looked at the Activity.
        try await server.control(["holdRequests": 99, "holdPath": "/files/movie"])
        let opening = Task { try await provider.preview(remote) }
        try #require(await eventually { !operations.activities.isEmpty })
        #expect(operations.activities.last?.state == .running)
        #expect(provider.metadata(for: remote) == nil)
        try await server.control(["releaseHold": true])
        _ = try await opening.value
        #expect(operations.activities.last?.state == .completed)
        await client.clearCaches()
    }

}
