import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct DriveSmallCopyTests {
    @Test func copiesUseBoundedConcurrencyAndVerifyEveryFile() async throws {
        let scratch = try Scratch()
        let bytes = Data(repeating: 120, count: 4096)
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let files: [[String: Any]] = (0..<12).map {
            [
                "id": "small-\($0)", "name": "small-\($0).txt", "mimeType": "text/plain", "size": "4096",
                "version": "1", "md5Checksum": md5, "capabilities": ["canDownload": true],
            ]
        }
        let fixture = scratch.url.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: [
            "files": files, "rootIDs": files.map { $0["id"]! },
            "generatedMedia": Dictionary(uniqueKeysWithValues: (0..<12).map { ("small-\($0)", 4096) }),
        ]).write(to: fixture)
        let server = try FakeDriveServer(fixture: fixture, latencyMS: 50)
        let (_, tokens, _) = try server.client()
        let client = DriveClient(
            accountID: UUID(), tokens: tokens, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("journal")),
            metadataDirectory: scratch.url.appendingPathComponent("metadata"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let items = try await client.list(DriveLocation(accountID: client.accountID))
        let sources = items.map { $0.location(accountID: client.accountID).url }
        let destination = scratch.url.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let control = FileJob(kind: .copy, sources: sources, destinationFolder: destination)
        let job = RemoteTransferJob(kind: .copy, sources: sources, destination: destination, control: control.control, rule: .ask, options: .init())
        await withCheckedContinuation { continuation in
            Thread {
                job.run(); continuation.resume()
            }.start()
        }
        #expect(job.errors.isEmpty && job.results.count == 12 && job.completed.count == 12 && control.hasEnded)
        #expect(job.progress.doneBytes == 12 * 4096 && job.progress.doneFiles == 12)
        for result in job.results { #expect(try Data(contentsOf: result) == bytes) }
        let stats = try await URLSession.shared.data(from: server.base.appendingPathComponent("__stats")).0
        let json = try #require(try JSONSerialization.jsonObject(with: stats) as? [String: Any])
        let concurrency = try #require(json["maxConcurrentMedia"] as? Int)
        #expect(concurrency > 1 && concurrency <= 6)
        let requests = try #require(json["requests"] as? [String])
        #expect(requests.filter { $0.contains("alt=media") }.count == 12)
        // Each file uses one media GET and one final revision check; the listing supplies its starting identity.
        #expect(requests.filter { $0.contains("/files/small-") }.count == 24)
    }
}
