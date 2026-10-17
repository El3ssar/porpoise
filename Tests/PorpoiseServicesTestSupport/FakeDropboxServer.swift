import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A local fake of Dropbox (scripts/fake-dropbox-server.py), one process and port per test.
public final class FakeDropboxServer {
    public let fixture: LocalFixtureServer
    public var base: URL { fixture.base }
    public var directory: URL { fixture.scratch.url.appendingPathComponent("Engine") }
    public init(latencyMS: Int = 0, connectionMbps: Int = 0, bandwidthMbps: Int = 0) throws {
        fixture = try LocalFixtureServer(
            script: TestPaths.script("fake-dropbox-server.py"),
            arguments: [
                "--latency-ms", String(latencyMS), "--connection-mbps", String(connectionMbps), "--bandwidth-mbps", String(bandwidthMbps),
            ])
    }
    public var config: DropboxConfiguration {
        DropboxConfiguration(
            appKey: "fixture-app", loopbackPort: 0, authorizationURL: base.appendingPathComponent("auth"),
            tokenURL: base.appendingPathComponent("token"),
            apiURL: base.appendingPathComponent("2"), contentURL: base.appendingPathComponent("2"), notifyURL: base.appendingPathComponent("2"))
    }
    public func client(id: UUID = UUID(), namespace: String? = nil, directory: URL? = nil) throws -> DropboxClient {
        let credentials = MemoryCredentials(); try credentials.save("fixture-refresh", clientID: config.appKey, accountID: id)
        return DropboxClient(
            accountID: id, configuration: config, tokens: DropboxTokens.session(configuration: config, accountID: id, credentials: credentials),
            namespaceID: namespace, directory: directory ?? self.directory)
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
