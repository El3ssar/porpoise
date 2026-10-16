import Foundation
import Testing

@testable import PorpoiseServices

struct CredentialStoresTests {
    @Test func allTestAndReviewLaunchSignalsSelectIsolation() {
        #expect(!CredentialStores.isolated(environment: [:], arguments: ["Porpoise"], testing: false))
        #expect(CredentialStores.drive(isolated: false) is DriveKeychainCredentials)
        for key in ["PORPOISE_DEFAULTS_SUITE", "PORPOISE_BRIDGE", "XCTestConfigurationFilePath", "SWIFT_TESTING_ENABLED"] {
            #expect(CredentialStores.isolated(environment: [key: "review"], arguments: [], testing: false))
        }
        #expect(CredentialStores.isolated(environment: [:], arguments: ["Porpoise"], testing: true))
        #expect(CredentialStores.isolated(environment: [:], arguments: ["/tmp/PorpoiseTests.xctest"], testing: false))
        #expect(CredentialStores.isolated(environment: [:], arguments: ["/tmp/swiftpm-testing-helper"], testing: false))
        #expect(CredentialStores.isIsolated)
        #expect(CredentialStores.drive() is MemoryCredentials)
        #expect(CredentialStores.passwords() is MemoryCredentials)
    }

    @Test func defaultDriveStoreSharesOnlyProcessMemory() throws {
        let id = UUID()
        let first = CredentialStores.drive(), second = CredentialStores.drive()
        try first.save("synthetic", clientID: "fixture", accountID: id)
        #expect(try second.read(clientID: "fixture", accountID: id) == "synthetic")
        #expect(try MemoryCredentials().read(clientID: "fixture", accountID: id) == nil)
        try second.remove(clientID: "fixture", accountID: id)
        #expect(try first.read(clientID: "fixture", accountID: id) == nil)
    }
    @Test func tokenManagerDefaultNeverReachesSystemCredentials() async throws {
        let manager = DriveTokenManager(configuration: DriveOAuthConfiguration(clientID: "fixture"), accountID: UUID())
        await #expect(throws: DriveError.reconnect) { try await manager.accessToken() }
        try await manager.revoke()
    }

}

struct CredentialQueryFailureTests {
    @Test func driveSurfacesFailuresAndRejectsNonDataCredentials() throws {
        let api = MemoryKeychainAPI()
        let store = DriveKeychainCredentials(api: api)
        let id = UUID()
        try store.save("fixture", clientID: "client", accountID: id)
        api.invalidData = true
        #expect(throws: DriveError.invalidResponse) { try store.read(clientID: "client", accountID: id) }
        api.failure = -50
        #expect(throws: DriveError.keychain(-50)) { try store.read(clientID: "client", accountID: id) }
        #expect(throws: DriveError.keychain(-50)) { try store.save("new", clientID: "client", accountID: id) }
        #expect(throws: DriveError.keychain(-50)) { try store.remove(clientID: "client", accountID: id) }
    }

    @Test func ftpFailsClosedWhenSecurityCannotReadCredentials() {
        let api = MemoryKeychainAPI()
        api.failure = -50
        #expect(Keychain(api: api).password(server: "nas.invalid", account: "me", scheme: "ftp") == nil)
    }
}
