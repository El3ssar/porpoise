import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A local fake of the Box API and its sign-in (scripts/fake-box-server.py), one process and port per test.
public final class FakeBoxServer {
    public let fixture: LocalFixtureServer
    public var base: URL { fixture.base }
    public var directory: URL { fixture.scratch.url.appendingPathComponent("Engine") }
    public init(latencyMS: Int = 0, connectionMbps: Int = 0, bandwidthMbps: Int = 0) throws {
        fixture = try LocalFixtureServer(
            script: TestPaths.script("fake-box-server.py"),
            arguments: [
                "--latency-ms", String(latencyMS), "--connection-mbps", String(connectionMbps), "--bandwidth-mbps", String(bandwidthMbps),
            ])
    }
    /// `chunkedThreshold`: files at least this large use a chunked session (small, so tests send small files).
    public func config(chunkedThreshold: Int64 = 20_000_000) -> BoxConfiguration {
        BoxConfiguration(
            clientID: "fixture-client", clientSecret: "fixture-secret", authorizationURL: base.appendingPathComponent("auth"),
            tokenURL: base.appendingPathComponent("oauth2/token"), revokeURL: base.appendingPathComponent("oauth2/revoke"),
            apiURL: base.appendingPathComponent("2.0"), uploadURL: base.appendingPathComponent("upload/2.0"), longPollTimeout: 10,
            chunkedThreshold: chunkedThreshold)
    }
    public var config: BoxConfiguration { config() }
    public func client(
        id: UUID = UUID(), directory: URL? = nil, chunkedThreshold: Int64 = 20_000_000, http: CloudHTTPTransport = .init(),
        retryWait: @escaping @Sendable (TimeInterval) async throws -> Void = CloudAuthorizedClient.defaultWait
    ) throws -> BoxClient {
        let config = config(chunkedThreshold: chunkedThreshold)
        let credentials = MemoryCredentials(); try credentials.save("fixture-refresh", clientID: config.clientID, accountID: id)
        return BoxClient(
            accountID: id, configuration: config, tokens: BoxTokens.session(configuration: config, accountID: id, credentials: credentials),
            directory: directory ?? self.directory, http: http, retryWait: retryWait)
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
