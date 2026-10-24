import Foundation
import PorpoiseCore

/// A Box OAuth 2.0 application. Box's token endpoint requires the application's client secret even for a desktop app
/// (https://developer.box.com/guides/authentication/oauth2/without-sdk/), so, like Google's desktop client, the build
/// carries one; it can't stay secret in an app anyone can download, and only identifies the application. PKCE is sent
/// as well. Loopback redirects may use any port (https://developer.box.com/guides/authentication/oauth2/oauth2-setup/).
public struct BoxConfiguration: Sendable {
    public var clientID: String
    public var clientSecret: String
    public var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var authorizationURL: URL
    public var tokenURL: URL
    public var revokeURL: URL
    public var apiURL: URL
    public var uploadURL: URL
    /// The longest a long poll for events is held open, whatever the realtime server asks.
    public var longPollTimeout: TimeInterval
    /// Files at least this large upload in a chunked session (Box's minimum for one is 20,000,000 bytes).
    public var chunkedThreshold: Int64
    public init(
        clientID: String, clientSecret: String,
        authorizationURL: URL = URL(string: "https://account.box.com/api/oauth2/authorize")!,
        tokenURL: URL = URL(string: "https://api.box.com/oauth2/token")!, revokeURL: URL = URL(string: "https://api.box.com/oauth2/revoke")!,
        apiURL: URL = URL(string: "https://api.box.com/2.0/")!, uploadURL: URL = URL(string: "https://upload.box.com/api/2.0/")!,
        longPollTimeout: TimeInterval = 620, chunkedThreshold: Int64 = 20_000_000
    ) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.authorizationURL = authorizationURL; self.tokenURL = tokenURL
        self.revokeURL = revokeURL; self.apiURL = apiURL; self.uploadURL = uploadURL; self.longPollTimeout = longPollTimeout
        self.chunkedThreshold = chunkedThreshold
    }
    /// The first source with a client ID gives both values, so an ID is never paired with another application's secret.
    public static func selected(
        defaults: UserDefaults = Settings.store, environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main, testing: Bool = Settings.isTesting
    ) -> Self {
        func nonempty(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let sources: [(String?, String?)] = [
            // The environment is for test instances only; the settings are the user's own app (Settings › Accounts).
            testing ? (TestEnvironment.boxClientID.value(in: environment), TestEnvironment.boxClientSecret.value(in: environment)) : (nil, nil),
            (defaults.string(forKey: "boxClientID"), try? BoxApplicationSecret.read(defaults: defaults)),
            (bundle.object(forInfoDictionaryKey: "BoxClientID") as? String, bundle.object(forInfoDictionaryKey: "BoxClientSecret") as? String),
        ]
        guard let source = sources.first(where: { nonempty($0.0) != nil }) else { return Self(clientID: "", clientSecret: "") }
        return Self(clientID: nonempty(source.0) ?? "", clientSecret: nonempty(source.1) ?? "")
    }
    /// True when `url` is the API or upload host itself: only there does a bearer token go.
    func isAPI(_ url: URL) -> Bool {
        [apiURL, uploadURL].contains { base in
            url.scheme == base.scheme && url.host?.lowercased() == base.host?.lowercased() && url.port == base.port && url.user == nil
                && url.password == nil
        }
    }
}

public struct BoxOAuthTransaction: Sendable {
    public let pkce: CloudPKCE
    public let configuration: BoxConfiguration
    public init(configuration: BoxConfiguration, redirectURL: URL) throws {
        guard configuration.isConfigured else { throw CloudOAuthError.configuration }
        self.configuration = configuration; pkce = try CloudPKCE(clientID: configuration.clientID, redirectURL: redirectURL)
    }
    /// Box's scopes are the application's own (set in its console); none are asked for here.
    public var authorizationURL: URL { pkce.authorizationURL(configuration.authorizationURL, clientID: configuration.clientID, parameters: []) }
    public func exchange(_ callback: URL, http: CloudHTTPTransport = .init()) async throws -> CloudOAuthToken {
        try await BoxTokens.request(
            [
                "client_id": configuration.clientID, "client_secret": configuration.clientSecret, "code": pkce.code(from: callback),
                "redirect_uri": pkce.redirectURL.absoluteString, "code_verifier": pkce.verifier, "grant_type": "authorization_code",
            ], configuration: configuration, http: http)
    }
}

public enum BoxTokens {
    /// Box refresh tokens are single use: each refresh's new one replaces the stored one (CloudOAuthSession.accept).
    public static func session(
        configuration: BoxConfiguration, accountID: UUID, credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "box"),
        http: CloudHTTPTransport = .init()
    ) -> CloudOAuthSession {
        CloudOAuthSession(clientID: configuration.clientID, accountID: accountID, credentials: credentials) { refresh in
            try await request(
                [
                    "client_id": configuration.clientID, "client_secret": configuration.clientSecret, "refresh_token": refresh,
                    "grant_type": "refresh_token",
                ], configuration: configuration, http: http)
        }
    }
    static func request(_ values: [String: String], configuration: BoxConfiguration, http: CloudHTTPTransport) async throws -> CloudOAuthToken {
        let (data, response) = try await http.postForm(configuration.tokenURL, values)
        // invalid_grant (revoked, expired, already used) and an unknown client are both "sign in again".
        guard response.statusCode != 400, response.statusCode != 401 else { throw CloudOAuthSession.refreshRejection(data) }
        try BoxClient.check(data, response)
        return try JSONDecoder().decode(CloudOAuthToken.self, from: data)
    }
    /// Ends the sign-in at Box. A failure leaves it to lapse unused (60 days); nothing is kept here either way.
    /// https://developer.box.com/reference/post-oauth2-revoke/
    static func revoke(_ token: String, configuration: BoxConfiguration, http: CloudHTTPTransport) async {
        _ = try? await http.postForm(
            configuration.revokeURL, ["client_id": configuration.clientID, "client_secret": configuration.clientSecret, "token": token])
    }
}
