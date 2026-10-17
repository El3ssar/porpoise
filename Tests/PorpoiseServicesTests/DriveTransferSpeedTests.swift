import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct DriveTransferSpeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_BENCHMARK"] == "1"))
    func throughput() async throws {
        let scratch = try Scratch()
        let size = 300 * 1024 * 1024
        let files: [[String: Any]] = (0...200).map { index in
            let count = index == 0 ? size : 4096
            return [
                "id": "speed-\(index)", "name": "speed-\(index).bin", "mimeType": "application/octet-stream",
                "size": String(count), "version": "1",
                "md5Checksum": Insecure.MD5.hash(data: Data(repeating: 120, count: count)).map { String(format: "%02x", $0) }.joined(),
                "capabilities": ["canDownload": true],
            ]
        }
        let fixture = scratch.url.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: [
            "files": files, "rootIDs": files.map { $0["id"]! },
            "generatedMedia": Dictionary(uniqueKeysWithValues: (0...200).map { ("speed-\($0)", $0 == 0 ? size : 4096) }),
        ]).write(to: fixture)
        let server = try FakeDriveServer(fixture: fixture, latencyMS: 50, bandwidthMbps: 100)
        let (_, tokens, _) = try server.client()
        let client = DriveClient(
            accountID: UUID(), tokens: tokens, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("journal")))
        for (label, indices) in [("300MiB", Array(0...0)), ("200small", Array(1...200))] {
            if label == "300MiB", ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_BENCHMARK_SMALL_ONLY"] == "1" { continue }
            let start = Date()
            if label == "200small" {
                let provider = DriveProvider(accountID: client.accountID, client: client)
                RemoteFS.registerDrive(provider, accountID: client.accountID)
                defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
                let listing = try await client.list(DriveLocation(accountID: client.accountID))
                let urls = listing.filter { $0.id != "speed-0" }.map { $0.location(accountID: client.accountID).url }
                let destination = scratch.url.appendingPathComponent("copies")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let job = RemoteTransferJob(
                    kind: .copy, sources: urls, destination: destination,
                    control: JobControl(), rule: .ask, options: .init())
                try await awaitCallback { continuation in
                    Thread {
                        job.run(); continuation.resume()
                    }.start()
                }
                #expect(job.errors.isEmpty && job.results.count == 200)
                let stats = try await URLSession.shared.data(from: server.base.appendingPathComponent("__stats")).0
                let json = try #require(try JSONSerialization.jsonObject(with: stats) as? [String: Any])
                let concurrent = try #require(json["maxConcurrentMedia"] as? Int)
                print("TRANSFER_BATCH maxConcurrentMedia=\(concurrent) results=\(job.results.count) errors=\(job.errors.count)")
                #expect(concurrent > 1 && concurrent <= 6)
                for url in job.results { #expect(try Data(contentsOf: url) == Data(repeating: 120, count: 4096)) }
            } else {
                for index in indices {
                    let file = try await client.file("speed-\(index)")
                    let result = try await client.downloadToStaging(file)
                    try FileManager.default.removeItem(at: result.url)
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            let bytes = label == "300MiB" ? size : 200 * 4096
            print("TRANSFER_BENCHMARK \(label) seconds=\(elapsed) MiB/s=\(Double(bytes) / 1048576 / elapsed) latency=50ms bandwidth=100Mbps")
        }
    }
}
