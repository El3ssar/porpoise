import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct OneDriveCallbackTests {
    @Test func registeredPortsPreferTheFirstFreeAndExplainExhaustion() throws {
        let configuration = OneDriveConfiguration(clientID: "fixture")
        #expect(configuration.loopbackPorts == [61846, 61847, 61848])
        func first(busy: Set<UInt16>) throws -> UInt16 {
            var tried: [UInt16] = []
            let selected: UInt16 = try configuration.makeLoopbackListener { port in
                tried.append(port)
                if busy.contains(port) { throw CloudOAuthLoopback.PortInUse(port: port) }
                return port
            }
            #expect(tried == Array(configuration.loopbackPorts.prefix(tried.count)))
            return selected
        }
        #expect(try first(busy: []) == 61846)
        #expect(try first(busy: [61846]) == 61847)
        #expect(try first(busy: [61846, 61847]) == 61848)
        #expect(throws: OneDriveCallbackError.portsBusy([61846, 61847, 61848])) {
            _ = try first(busy: [61846, 61847, 61848])
        }
        let error = OneDriveCallbackError.portsBusy(configuration.loopbackPorts).localizedDescription
        #expect(error.contains("in use") && error.contains("try again"))
        #expect(configuration.loopbackPorts.allSatisfy { error.contains(String($0)) })
        // A non-collision error must not silently select a different port.
        var attempts = 0
        #expect(throws: CloudOAuthError.self) {
            let _: UInt16 = try configuration.makeLoopbackListener { _ in
                attempts += 1
                throw CloudOAuthError.invalidResponse
            }
        }
        #expect(attempts == 1)
    }

    @Test func isolatedFixtureExplicitlyUsesAnEphemeralPort() throws {
        let configuration = OneDriveConfiguration(clientID: "fixture", loopbackPort: 0)
        #expect(configuration.loopbackPorts == [0])
        let listener = try configuration.makeLoopbackListener()
        #expect(listener.redirectURL.host == "127.0.0.1")
        #expect(listener.redirectURL.port != nil && listener.redirectURL.port != 0)
    }

    /// Exercise the account-store listener choice, not only the configuration helper. Each test uses its own
    /// random ports below the ephemeral range; it never reserves the production callback ports.
    @Test @MainActor func accountSignInUsesConfiguredPorts() async throws {
        let server = try FakeGraphServer(), scratch = try Scratch()
        var configuration = server.config
        configuration.loopbackPort = UInt16.random(in: 20000...40000)
        let store = OneDriveAccountStore(
            defaults: MemoryDefaults(), credentials: MemoryCredentials(), configuration: configuration, directory: scratch.url)
        let account = try await store.connect { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = query.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
            #expect(redirect?.host == "127.0.0.1" && redirect?.path == "/oauth/callback")
            #expect(configuration.loopbackPorts.contains { Int($0) == redirect?.port })
            openInFakeBrowser(url)
        }
        #expect(account.userID == "fixture-user")
    }

    @Test func tokenExchangeUsesExactRedirectAndKeepsPKCEValidation() async throws {
        let redirect = URL(string: "http://127.0.0.1:31846/oauth/callback")!
        let transaction = try OneDriveOAuthTransaction(configuration: .init(clientID: "fixture"), redirectURL: redirect)
        let authorization = URLComponents(url: transaction.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authorization.first { $0.name == "redirect_uri" }?.value == redirect.absoluteString)
        #expect(authorization.first { $0.name == "code_challenge_method" }?.value == "S256")
        let callback = URL(string: redirect.absoluteString + "?state=\(transaction.pkce.state)&code=fixture-code")!
        let http = CloudHTTPTransport(send: { request in
            #expect(request.url == transaction.configuration.tokenURL && request.httpMethod == "POST")
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            let form = URLComponents(string: "http://fixture.invalid/?" + body)?.queryItems ?? []
            #expect(form.first { $0.name == "redirect_uri" }?.value == redirect.absoluteString)
            #expect(form.first { $0.name == "code_verifier" }?.value == transaction.pkce.verifier)
            #expect(form.first { $0.name == "code" }?.value == "fixture-code")
            return (
                Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8),
                try #require(HTTPURLResponse(url: transaction.configuration.tokenURL, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        })
        _ = try await transaction.exchange(callback, http: http)
        func expectStateRejection(_ callback: URL) {
            do {
                _ = try transaction.pkce.code(from: callback)
                Issue.record("Accepted an invalid callback")
            } catch CloudOAuthError.state {
                // The callback must fail identity/state validation before code exchange.
            } catch {
                Issue.record("Expected state rejection, received \(error)")
            }
        }
        for invalid in [
            "http://127.0.0.1:31847/oauth/callback", "http://localhost:31846/oauth/callback",
            "http://127.0.0.1:31846/other", "https://127.0.0.1:31846/oauth/callback",
        ] {
            let callback = URL(string: invalid + "?state=\(transaction.pkce.state)&code=fixture-code")!
            expectStateRejection(callback)
        }
        expectStateRejection(URL(string: redirect.absoluteString + "?state=wrong&code=fixture-code")!)
    }
}
