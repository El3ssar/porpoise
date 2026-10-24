import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudTokenRecoveryTests {
    @Test(arguments: ["drive", "dropbox", "box", "onedrive"])
    func reconnectIsFencedWithoutDeletingAnUnprovenCredential(_ provider: String) async throws {
        let credentials = MemoryCredentials(), account = UUID(), attempts = Counter()
        try credentials.save("revoked", clientID: "fixture", accountID: account)
        let session = CloudOAuthSession(clientID: "fixture", accountID: account, credentials: credentials) { _ in
            attempts.add()
            switch provider {
            case "drive": throw DriveError.reconnect
            case "dropbox": throw DropboxError.reconnect
            case "box": throw BoxError.reconnect
            default: throw OneDriveError.reconnect
            }
        }
        for _ in 0..<10 {
            do { _ = try await session.accessToken(); Issue.record("Revoked grant accepted") } catch {
                #expect((error as? any CloudReconnectFailure)?.needsSignIn == true)
            }
        }
        #expect(attempts.value == 1)
        #expect(try credentials.read(clientID: "fixture", accountID: account) == "revoked")
        try await session.accept(CloudOAuthToken(access_token: "new access", expires_in: 3600, refresh_token: "new refresh", token_type: "Bearer"))
        #expect(try await session.accessToken() == "new access")
        #expect(try credentials.read(clientID: "fixture", accountID: account) == "new refresh")
        #expect(attempts.value == 1)
    }

    @Test(arguments: ["invalid_grant", "invalid_request", "invalid_client", "proxy error"])
    func onlyInvalidGrantDeletesTheCredential(_ code: String) async throws {
        let credentials = MemoryCredentials(), account = UUID()
        try credentials.save("saved refresh", clientID: "fixture", accountID: account)
        let body = try JSONSerialization.data(withJSONObject: ["error": code])
        let session = CloudOAuthSession(clientID: "fixture", accountID: account, credentials: credentials) { _ in
            throw CloudOAuthSession.refreshRejection(body)
        }
        do { _ = try await session.accessToken(); Issue.record("Rejected refresh accepted") } catch {}
        #expect(try credentials.read(clientID: "fixture", accountID: account) == (code == "invalid_grant" ? nil : "saved refresh"))
    }

    @Test func transientRefreshFailureRemainsRetryable() async throws {
        let credentials = MemoryCredentials(), account = UUID(), attempts = Counter()
        try credentials.save("valid", clientID: "fixture", accountID: account)
        let session = CloudOAuthSession(clientID: "fixture", accountID: account, credentials: credentials) { _ in
            attempts.add()
            if attempts.value == 1 { throw URLError(.networkConnectionLost) }
            return CloudOAuthToken(access_token: "recovered", expires_in: 3600, refresh_token: nil, token_type: "Bearer")
        }
        await #expect(throws: URLError.self) { try await session.accessToken() }
        #expect(try await session.accessToken() == "recovered" && attempts.value == 2)
        #expect(try credentials.read(clientID: "fixture", accountID: account) == "valid")
    }
}
