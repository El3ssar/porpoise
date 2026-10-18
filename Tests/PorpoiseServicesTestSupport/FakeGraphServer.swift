import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A local fake of Microsoft Graph and its sign-in (scripts/fake-graph-server.py), one process and port per test.
public final class FakeGraphServer {
    /// The fixture's own drive, and the drive its shared items live in.
    public static let drive = "fixture-drive!A1", otherDrive = "other-drive!B2"
    public let fixture: LocalFixtureServer
    public var base: URL { fixture.base }
    public var directory: URL { fixture.scratch.url.appendingPathComponent("Engine") }
    public init(latencyMS: Int = 0, connectionMbps: Int = 0, bandwidthMbps: Int = 0) throws {
        fixture = try LocalFixtureServer(
            script: TestPaths.script("fake-graph-server.py"),
            arguments: [
                "--latency-ms", String(latencyMS), "--connection-mbps", String(connectionMbps), "--bandwidth-mbps", String(bandwidthMbps),
            ])
    }
    public var config: OneDriveConfiguration {
        OneDriveConfiguration(
            clientID: "fixture-client", authorizationURL: base.appendingPathComponent("auth"), tokenURL: base.appendingPathComponent("token"),
            graphURL: base.appendingPathComponent("v1.0"), pollInterval: 0)
    }
    public func client(id: UUID = UUID(), drive: String = FakeGraphServer.drive, directory: URL? = nil) throws -> OneDriveClient {
        let credentials = MemoryCredentials(); try credentials.save("fixture-refresh", clientID: config.clientID, accountID: id)
        return OneDriveClient(
            accountID: id, configuration: config,
            tokens: OneDriveTokens.session(configuration: config, accountID: id, credentials: credentials), driveID: drive,
            directory: directory ?? self.directory)
    }
    public func configure(_ values: [String: Any]) async throws {
        var request = URLRequest(url: base.appendingPathComponent("config")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        let (_, response) = try await URLSession.shared.data(for: request); #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
    public func stats() async throws -> [String: Any] {
        let (bytes, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    public func requests() async throws -> [[String: Any]] { try await stats()["requests"] as? [[String: Any]] ?? [] }
}
