import Foundation
import Testing

@testable import PorpoiseServices

struct BoxApplicationSecretTests {
    private struct Unavailable: CloudCredentialStore {
        func read(clientID: String, accountID: UUID) throws -> String? { throw CloudCredentialError.invalidResponse }
        func save(_ token: String, clientID: String, accountID: UUID) throws { throw CloudCredentialError.invalidResponse }
        func remove(clientID: String, accountID: UUID) throws { throw CloudCredentialError.invalidResponse }
    }
    @Test func migrationAndEditsKeepPreferencesFreeOfSecrets() throws {
        let suite = "porpoise-secret-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)), credentials = MemoryCredentials()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("app", forKey: "boxClientID"); defaults.set("legacy", forKey: "boxClientSecret")
        #expect(throws: (any Error).self) { try BoxApplicationSecret.read(defaults: defaults, credentials: Unavailable()) }
        #expect(defaults.string(forKey: "boxClientSecret") == "legacy")
        #expect(try BoxApplicationSecret.read(defaults: defaults, credentials: credentials) == "legacy")
        #expect(defaults.object(forKey: "boxClientSecret") == nil)
        try BoxApplicationSecret.save("edited", defaults: defaults, credentials: credentials)
        #expect(try BoxApplicationSecret.read(defaults: defaults, credentials: credentials) == "edited")
        #expect(defaults.object(forKey: "boxClientSecret") == nil)
        try BoxApplicationSecret.save("", defaults: defaults, credentials: credentials)
        #expect(try BoxApplicationSecret.read(defaults: defaults, credentials: credentials) == nil)
    }
}
