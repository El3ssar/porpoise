import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct CloudFirstInstallTests {
    @Test(arguments: ["server_error", "temporarily_unavailable", "invalid_scope", "unauthorized_client", "unsupported_response_type"])
    func providerAuthorizationFailuresAreNotSilentCancellation(_ reason: String) throws {
        let redirect = URL(string: "http://127.0.0.1:12345/oauth/callback")!
        let transaction = try CloudPKCE(clientID: "fixture-app", redirectURL: redirect)
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            .init(name: "state", value: transaction.state), .init(name: "error", value: reason),
            .init(name: "error_description", value: "do-not-echo-provider-details"),
        ]
        do {
            _ = try transaction.code(from: try #require(callback.url))
            Issue.record("An unsuccessful authorization cannot yield a code")
        } catch {
            guard case .failed(let message) = CloudConnectError.from(error, account: { _ in nil }) else {
                Issue.record("A provider failure must produce a retryable error, not silent cancellation")
                return
            }
            #expect(message.contains("Try") && !message.contains("do-not-echo-provider-details"))
            let drive = driveOAuthError(error)
            guard case .failed = CloudConnectError.from(drive, account: { _ in nil }) else {
                Issue.record("Drive must retain the authorization failure"); return
            }
        }
    }

    @Test func consentCancellationStillCancelsAndInvalidStateStillFailsFirst() throws {
        let redirect = URL(string: "http://127.0.0.1:12345/oauth/callback")!
        let transaction = try CloudPKCE(clientID: "fixture-app", redirectURL: redirect)
        for state in [transaction.state, "wrong"] {
            let url = try #require(URL(string: "\(redirect)?state=\(state)&error=access_denied"))
            do { _ = try transaction.code(from: url); Issue.record("A denied authorization must fail") } catch {
                let result = CloudConnectError.from(error, account: { _ in nil })
                if state == transaction.state {
                    #expect(result == .cancelled)
                } else {
                    guard case .failed = result else { Issue.record("An invalid state must not look cancelled"); return }
                }
            }
        }
    }

    @Test(arguments: ["error=", "error=access_denied&error=server_error", "error=server_error&code=unexpected"])
    func malformedErrorCallbacksDoNotMasqueradeAsCancellation(_ query: String) throws {
        let transaction = try CloudPKCE(clientID: "fixture", redirectURL: URL(string: "http://127.0.0.1:12345/oauth/callback")!)
        let callback = try #require(URL(string: "\(transaction.redirectURL)?state=\(transaction.state)&\(query)"))
        do { _ = try transaction.code(from: callback); Issue.record("Malformed callback accepted") } catch {
            guard case .failed = CloudConnectError.from(error, account: { _ in nil }) else {
                Issue.record("Malformed callback must be reported, not silently dismissed"); return
            }
        }
    }

    @Test func sharedSignInFailuresHaveUsefulRetryInstructions() {
        #expect(DriveError.configuration.localizedDescription.contains("this build"))
        #expect(!DriveError.configuration.localizedDescription.contains("Settings"))
        for error in [CloudOAuthError.configuration, .state, .invalidResponse, .timeout, .random(-1)] {
            guard case .failed(let message) = CloudConnectError.from(error, account: { _ in nil }) else {
                Issue.record("A failed sign-in must report its cause"); continue
            }
            #expect(!message.contains("CloudOAuthError") && !message.contains("couldn’t be completed"))
            #expect(message.contains("Try") || message.contains("configured"))
        }
    }

    @Test(arguments: [false, true])
    func aFreshDriveConnectionRequiresADurableRefreshTokenAndCanRetry(empty: Bool) async throws {
        let defaults = MemoryDefaults(), credentials = MemoryCredentials()
        let fixture = HTTPFixture(refresh: empty ? "" : nil)
        let config = DriveOAuthConfiguration(
            clientID: "fixture-first-install", authorizationURL: URL(string: "https://fixture.invalid/auth")!,
            tokenURL: URL(string: "https://fixture.invalid/token")!, profileURL: URL(string: "https://fixture.invalid/userinfo")!)
        let store = DriveAccountStore(
            defaults: defaults, credentials: credentials, http: DriveHTTP(send: { try await fixture.send($0) }), configuration: config,
            baseURL: URL(string: "https://fixture.invalid/drive/v3/")!)
        var pages: [Task<Data, Error>] = []
        let browser: @MainActor (URL) -> Void = { address in
            pages.append(
                Task {
                    let source = try #require(URLComponents(url: address, resolvingAgainstBaseURL: false))
                    let redirect = try #require(source.queryItems?.first { $0.name == "redirect_uri" }?.value)
                    let state = try #require(source.queryItems?.first { $0.name == "state" }?.value)
                    var callback = try #require(URLComponents(string: redirect))
                    guard callback.host == "127.0.0.1" else { throw CloudOAuthError.invalidResponse }
                    callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "fixture-code")]
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    return try await session.data(from: try #require(callback.url)).0
                })
        }
        defer {
            pages.forEach { $0.cancel() }
            for account in store.accounts {
                store.client(for: account.id)?.stopPolling()
                RemoteFS.unregisterDrive(accountID: account.id)
            }
        }
        await #expect(throws: DriveError.reconnect) { try await store.connect(openBrowser: browser) }
        for page in pages { _ = try await page.value }
        #expect(store.accounts.isEmpty && !store.connecting)
        #expect(defaults.data(forKey: "googleDriveAccounts") == nil)
        guard store.accounts.isEmpty else { return }  // Keep the pre-fix negative run self-contained.
        await fixture.setRefresh("fixture-durable-refresh")
        let account = try await store.connect(openBrowser: browser)
        #expect(store.accounts == [account])
        #expect(try credentials.read(clientID: config.clientID, accountID: account.id) == "fixture-durable-refresh")
        let persisted = try #require(defaults.data(forKey: "googleDriveAccounts"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("fixture-durable-refresh"))
        let restored = DriveAccountStore(
            defaults: defaults, credentials: credentials, http: DriveHTTP(send: { try await fixture.send($0) }), configuration: config,
            baseURL: URL(string: "https://fixture.invalid/drive/v3/")!)
        defer { restored.client(for: account.id)?.stopPolling() }
        #expect(restored.accounts == [account])
        let client = try #require(restored.client(for: account.id))
        #expect(try await client.tokens.accessToken() == "fixture-access")
        for page in pages { _ = try await page.value }
    }

    private actor HTTPFixture {
        var refresh: String?
        init(refresh: String?) { self.refresh = refresh }
        func setRefresh(_ refresh: String) { self.refresh = refresh }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, url.host == "fixture.invalid" else { throw URLError(.unsupportedURL) }
            let body: [String: Any]
            switch url.path {
            case "/token":
                var token: [String: Any] = [
                    "access_token": "fixture-access", "expires_in": 3600, "token_type": "Bearer",
                    "scope": "openid email profile https://www.googleapis.com/auth/drive",
                ]
                token["refresh_token"] = refresh
                body = token
            case "/userinfo": body = ["sub": "fixture-user", "email": "fresh@example.invalid", "name": "Fixture"]
            case "/drive/v3/changes/startPageToken": body = ["startPageToken": "fixture-page"]
            case "/drive/v3/changes": body = ["changes": [], "newStartPageToken": "fixture-page"]
            default: throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: body), response)
        }
    }
}
