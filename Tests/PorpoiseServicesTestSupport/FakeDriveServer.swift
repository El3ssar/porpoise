import CryptoKit
import Foundation
import PorpoiseServices
import PorpoiseTestSupport

/// A local fake of Google Drive (scripts/fake-drive-server.py): each test owns its process and ephemeral port. No live
/// account, real Keychain or external network.
public final class FakeDriveServer {
    private let fixtureServer: LocalFixtureServer
    public var process: Process { fixtureServer.process }
    public var scratch: Scratch { fixtureServer.scratch }
    public var base: URL { fixtureServer.base }

    /// `holdMedia`: the fake holds each media GET until that many are in flight at once (30 s at most, then it lets all
    /// through), so `maxConcurrentMedia` shows a concurrent client's concurrency however slow the machine; 0 holds none.
    /// `control(["holdRequests": n, "holdPath": "/files/x-"])` arms the same gate later, for any Drive GET path.
    public init(fixture: URL? = nil, latencyMS: Int = 0, bandwidthMbps: Int = 0, connectionMbps: Int = 0, holdMedia: Int = 0) throws {
        do {
            fixtureServer = try LocalFixtureServer(
                script: TestPaths.script("fake-drive-server.py"), fixture: fixture,
                arguments: [
                    "--latency-ms", String(latencyMS), "--bandwidth-mbps", String(bandwidthMbps), "--connection-mbps", String(connectionMbps),
                    "--hold-media", String(holdMedia),
                ])
        } catch { throw DriveError.invalidResponse }
    }

    /// A fixture in Tests/PorpoiseServicesTests/Fixtures/Drive.
    public static func fixture(_ name: String) -> URL { TestPaths.fixtures.appendingPathComponent("Drive").appendingPathComponent(name) }

    /// Writes a fixture of the test's own (files, generated media…) as fixture.json in `scratch`.
    public static func writeFixture(in scratch: Scratch, _ json: [String: Any]) throws -> URL {
        let url = scratch.url.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    /// The MD5 the fake reports for `generatedMedia` of `size` bytes (it serves that many bytes of "x").
    public static func generatedMediaMD5(size: Int) -> String {
        Insecure.MD5.hash(data: Data(repeating: 120, count: size)).map { String(format: "%02x", $0) }.joined()
    }

    public func stop() { fixtureServer.stop() }

    public var config: DriveOAuthConfiguration {
        DriveOAuthConfiguration(
            clientID: "fixture-client", authorizationURL: base.appendingPathComponent("auth"), tokenURL: base.appendingPathComponent("token"),
            revokeURL: base.appendingPathComponent("revoke"), profileURL: base.appendingPathComponent("userinfo"))
    }

    /// A client signed in to the fake (its refresh token in memory).
    public func client(id: UUID = UUID(), refresh: String = "fixture-refresh") throws -> (DriveClient, DriveTokenManager, MemoryCredentials) {
        let credentials = MemoryCredentials()
        try credentials.save(refresh, clientID: config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: config, accountID: id, credentials: credentials)
        return (DriveClient(accountID: id, tokens: tokens, baseURL: base.appendingPathComponent("drive/v3/")), tokens, credentials)
    }

    /// An account store signed in through this fake (its tokens in memory, its settings in `defaults`).
    @MainActor public func accountStore(defaults: UserDefaults = MemoryDefaults()) -> DriveAccountStore {
        DriveAccountStore(
            defaults: defaults, credentials: MemoryCredentials(), configuration: config, baseURL: base.appendingPathComponent("drive/v3/"))
    }

    /// The app's Drive backend over a fresh `accountStore()`, its avatars in `scratch`.
    @MainActor public func backend(scratch: Scratch, defaults: UserDefaults = MemoryDefaults()) -> (DriveCloudBackend, DriveAccountStore) {
        let store = accountStore(defaults: defaults)
        return (DriveCloudBackend(store: store, avatarFolder: scratch.url.appendingPathComponent("avatars")), store)
    }

    /// Changes how the fake behaves from now on (`__control`: conflicts on save, remote changes, failures…).
    public func control(_ values: [String: Any]) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        _ = try await URLSession.shared.data(for: request)
    }

    /// What the fake has seen (`__stats`: requests, ranges, media bytes, the most concurrent media and Drive requests…).
    public func stats() async throws -> [String: Any] {
        let data = try await URLSession.shared.data(from: base.appendingPathComponent("__stats")).0
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DriveError.invalidResponse }
        return json
    }
}
