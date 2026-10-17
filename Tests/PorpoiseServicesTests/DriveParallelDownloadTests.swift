import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveParallelDownloadTests {
    private func fixture(_ scratch: Scratch, size: Int) throws -> URL {
        let digest = FakeDriveServer.generatedMediaMD5(size: size)
        return try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": [
                    [
                        "id": "big", "name": "big.bin", "mimeType": "application/octet-stream", "size": String(size),
                        "version": "1", "md5Checksum": digest, "capabilities": ["canDownload": true],
                    ]
                ],
                "generatedMedia": ["big": size],
            ])
    }

    @Test func rangesCompleteAndWarmStagingDoesNotTransferAgain() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 32 << 20))
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("big"), id = UUID()
        let result = try await client.downloadToStaging(file, operationID: id)
        let record = try #require(try client.mutationJournal.load(id))
        #expect(record.downloadRanges?.count == 4)
        #expect(record.downloadRanges?.allSatisfy { $0.offset == $0.end } == true)
        #expect(record.offset == 32 << 20 && record.phase == .done)
        #expect(try DriveClient.md5(result.url) == file.md5Checksum)
        let second = try await client.downloadToStaging(file, operationID: id)
        #expect(second.url == result.url)
    }

    @Test func interruptedRangesResumeAndCancellationAuthenticatesPartial() async throws {
        let scratch = try Scratch(), checks = DriveMutationTests()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 64 << 20), connectionMbps: 200)
        let client = try checks.client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("big"), id = UUID()
        try await server.control(["dropDownloadAfterBytes": 10 << 20])
        await #expect(throws: (any Error).self) { try await client.downloadToStaging(file, operationID: id) }
        let record = try #require(try client.mutationJournal.load(id))
        #expect(record.phase != .done && record.downloadRanges?.count == 4)
        let before = try await server.stats()
        let beforeCount = try #require(before["ranges"] as? [String]).count
        let result = try await client.downloadToStaging(file, operationID: id)
        #expect(try DriveClient.md5(result.url) == file.md5Checksum)
        let after = try await server.stats()
        let resumed = try #require(after["ranges"] as? [String]).dropFirst(beforeCount)
        let missing = try #require(record.downloadRanges).filter { $0.offset < $0.end }.map { "bytes=\($0.offset)-\($0.end - 1)" }
        #expect(Set(resumed) == Set(missing))
        let cancelledID = UUID()
        try await server.control(["dropDownloadAfterBytes": 1 << 20])
        await #expect(throws: (any Error).self) { try await client.downloadToStaging(file, operationID: cancelledID) }
        try await client.cancelTransfer(cancelledID)
        let cancelled = try #require(try client.mutationJournal.load(cancelledID))
        #expect(cancelled.downloadRanges == nil && cancelled.offset == 0 && cancelled.fingerprint == nil)
    }

    @Test func parallelRevisionAndChecksumStillFailClosed() async throws {
        for changedRevision in [false, true] {
            let scratch = try Scratch(), checks = DriveMutationTests()
            let url = try fixture(scratch, size: 32 << 20)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if !changedRevision {
                var files = try #require(json["files"] as? [[String: Any]])
                files[0]["md5Checksum"] = "incorrect"
                json["files"] = files
                try JSONSerialization.data(withJSONObject: json).write(to: url)
            }
            let server = try FakeDriveServer(fixture: url)
            let client = try checks.client(server, folder: scratch.url.appendingPathComponent("journal"))
            let file = try await client.file("big"), id = UUID()
            if changedRevision { try await server.control(["changeRevisionDuringDownload": true]) }
            await #expect(throws: (any Error).self) { try await client.downloadToStaging(file, operationID: id) }
            #expect(try client.mutationJournal.load(id)?.phase != .done)
        }
    }

    @Test func truncatedPreallocatedPartialFailsClosed() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 32 << 20))
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("big"), id = UUID()
        let directory = client.mutationJournal.folder.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(id.uuidString + ".part")
        try Data().write(to: partial)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: 32 << 20)
        var record = DriveMutationRecord(operationID: id, accountID: client.accountID, kind: "download", sourceID: "big")
        record.revision = file.version; record.phase = .transferring; record.fingerprint = JobJournal.Fingerprint(partial)
        record.downloadRanges = (0..<4).map { index in
            .init(start: Int64(index) << 23, end: Int64(index + 1) << 23, offset: Int64(index) << 23)
        }
        try client.mutationJournal.save(record)
        try handle.truncate(atOffset: 4096); try handle.close()
        await #expect(throws: DriveMutationError.sourceChanged) { try await client.downloadToStaging(file, operationID: id) }
        #expect(try client.mutationJournal.load(id)?.phase != .done)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_BENCHMARK"] == "1"))
    func perConnectionThroughput() async throws {
        let scratch = try Scratch()
        let server = try FakeDriveServer(fixture: fixture(scratch, size: 300 << 20), latencyMS: 50, bandwidthMbps: 400, connectionMbps: 40)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("journal"))
        let file = try await client.file("big")
        for connections in [1, 8] {
            let start = Date()
            let result = try await client.downloadToStaging(file, maximumConnections: connections)
            let elapsed = Date().timeIntervalSince(start)
            #expect(try DriveClient.md5(result.url) == file.md5Checksum)
            print(
                "PARALLEL_BENCHMARK 300MiB maximumConnections=\(connections) seconds=\(elapsed) MiB/s=\(300 / elapsed) connection=40Mbps total=400Mbps"
            )
            try FileManager.default.removeItem(at: result.url)
        }
    }
}
