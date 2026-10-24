import Foundation
import PorpoiseCore

/// Microsoft identity platform (v2.0) public client: PKCE, no client secret, a loopback redirect whose port Microsoft
/// ignores for native apps (https://learn.microsoft.com/entra/identity-platform/reply-url#localhost-exceptions).
public struct OneDriveConfiguration: Sendable {
    public var clientID: String
    public var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var authorizationURL: URL
    public var tokenURL: URL
    public var graphURL: URL
    /// How long the change feed waits between delta checks (Graph has no long poll for a desktop app).
    public var pollInterval: TimeInterval
    public init(
        clientID: String,
        authorizationURL: URL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        graphURL: URL = URL(string: "https://graph.microsoft.com/v1.0/")!, pollInterval: TimeInterval = 30
    ) {
        self.clientID = clientID; self.authorizationURL = authorizationURL; self.tokenURL = tokenURL; self.graphURL = graphURL
        self.pollInterval = pollInterval
    }
    public static func selected(
        defaults: UserDefaults = Settings.store, environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main, testing: Bool = Settings.isTesting
    ) -> Self {
        func nonempty(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        return Self(
            // The environment is for test instances only; the setting is the user's own app registration (Settings › Accounts).
            clientID: nonempty(testing ? TestEnvironment.oneDriveClientID.value(in: environment) : nil)
                ?? nonempty(defaults.string(forKey: "oneDriveClientID"))
                ?? nonempty(bundle.object(forInfoDictionaryKey: "OneDriveClientID") as? String) ?? "")
    }
    /// offline_access gives the refresh token; Files.ReadWrite.All also reaches what others shared.
    public static let scopes = "offline_access User.Read Files.ReadWrite.All"
    /// True when `url` is on the Graph host itself: only there does a bearer token go (paging and delta links included).
    func isGraph(_ url: URL) -> Bool {
        url.scheme == graphURL.scheme && url.host?.lowercased() == graphURL.host?.lowercased() && url.port == graphURL.port
            && url.user == nil && url.password == nil
    }
}

public struct OneDriveOAuthTransaction: Sendable {
    public let pkce: CloudPKCE
    public let configuration: OneDriveConfiguration
    public init(configuration: OneDriveConfiguration, redirectURL: URL) throws {
        self.configuration = configuration; pkce = try CloudPKCE(clientID: configuration.clientID, redirectURL: redirectURL)
    }
    public var authorizationURL: URL {
        pkce.authorizationURL(
            configuration.authorizationURL, clientID: configuration.clientID,
            parameters: [
                .init(name: "scope", value: OneDriveConfiguration.scopes), .init(name: "response_mode", value: "query"),
                .init(name: "prompt", value: "select_account"),
            ])
    }
    public func exchange(_ callback: URL, http: CloudHTTPTransport = .init()) async throws -> CloudOAuthToken {
        try await OneDriveTokens.request(
            [
                "client_id": configuration.clientID, "code": pkce.code(from: callback), "redirect_uri": pkce.redirectURL.absoluteString,
                "code_verifier": pkce.verifier, "grant_type": "authorization_code", "scope": OneDriveConfiguration.scopes,
            ], configuration: configuration, http: http)
    }
}

public enum OneDriveTokens {
    /// Microsoft rotates refresh tokens: each refresh's new one replaces the stored one (CloudOAuthSession.accept).
    public static func session(
        configuration: OneDriveConfiguration, accountID: UUID,
        credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "onedrive"), http: CloudHTTPTransport = .init()
    ) -> CloudOAuthSession {
        CloudOAuthSession(clientID: configuration.clientID, accountID: accountID, credentials: credentials) { refresh in
            try await request(
                [
                    "client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token",
                    "scope": OneDriveConfiguration.scopes,
                ], configuration: configuration, http: http)
        }
    }
    static func request(_ values: [String: String], configuration: OneDriveConfiguration, http: CloudHTTPTransport) async throws
        -> CloudOAuthToken
    {
        let (data, response) = try await http.postForm(configuration.tokenURL, values)
        // invalid_grant (revoked, expired, password changed) and an unknown client are both "sign in again".
        guard response.statusCode != 400, response.statusCode != 401 else { throw CloudOAuthSession.refreshRejection(data) }
        try OneDriveClient.check(data, response)
        return try JSONDecoder().decode(CloudOAuthToken.self, from: data)
    }
}
