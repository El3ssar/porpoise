import CryptoKit
import Foundation
import Security

public struct DriveOAuthConfiguration: Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var authorizationURL: URL
    public var tokenURL: URL
    public var revokeURL: URL
    public var profileURL: URL

    public init(
        clientID: String, clientSecret: String? = nil,
        authorizationURL: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revokeURL: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
        profileURL: URL = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    ) {
        self.clientID = clientID; self.clientSecret = clientSecret
        self.authorizationURL = authorizationURL; self.tokenURL = tokenURL
        self.revokeURL = revokeURL; self.profileURL = profileURL
    }
}

public typealias DriveCredentialStore = CloudCredentialStore

public struct DriveKeychainCredentials: DriveCredentialStore, @unchecked Sendable {
    private let store: CloudKeychainCredentials
    public init() { store = CloudKeychainCredentials(providerID: "google-drive") }
    init(api: any KeychainAPI) { store = CloudKeychainCredentials(providerID: "google-drive", api: api) }
    public func read(clientID: String, accountID: UUID) throws -> String? {
        do { return try store.read(clientID: clientID, accountID: accountID) } catch { throw driveOAuthError(error) }
    }
    public func save(_ token: String, clientID: String, accountID: UUID) throws {
        do { try store.save(token, clientID: clientID, accountID: accountID) } catch { throw driveOAuthError(error) }
    }
    public func remove(clientID: String, accountID: UUID) throws {
        do { try store.remove(clientID: clientID, accountID: accountID) } catch { throw driveOAuthError(error) }
    }
}

typealias DriveTokenResponse = CloudOAuthToken

/// A fresh transaction for each sign-in. Only a matching loopback path, state and one code are accepted.
public struct DriveOAuthTransaction: Sendable {
    private let pkce: CloudPKCE
    public var verifier: String { pkce.verifier }
    public var state: String { pkce.state }
    public let redirectURL: URL
    public let configuration: DriveOAuthConfiguration
    public let loginHint: String?
    public init(configuration: DriveOAuthConfiguration, redirectURL: URL, loginHint: String? = nil) throws {
        self.configuration = configuration; self.redirectURL = redirectURL; self.loginHint = loginHint
        do { pkce = try CloudPKCE(clientID: configuration.clientID, redirectURL: redirectURL) } catch { throw driveOAuthError(error) }
    }
    static func base64URL(_ data: Data) -> String { CloudPKCE.base64URL(data) }
    public var authorizationURL: URL {
        var parameters = [
            URLQueryItem(name: "scope", value: "openid email profile https://www.googleapis.com/auth/drive"),
            URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint { parameters.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        return pkce.authorizationURL(configuration.authorizationURL, clientID: configuration.clientID, parameters: parameters)
    }
    public func code(from callback: URL) throws -> String {
        do { return try pkce.code(from: callback) } catch { throw driveOAuthError(error) }
    }

    func exchange(_ callback: URL, http: DriveHTTP) async throws -> DriveTokenResponse {
        var values = [
            "client_id": configuration.clientID, "code": try code(from: callback),
            "redirect_uri": redirectURL.absoluteString, "code_verifier": verifier, "grant_type": "authorization_code",
        ]
        values["client_secret"] = configuration.clientSecret
        return try await DriveTokenManager.request(values, configuration: configuration, http: http)
    }
}

/// Access tokens remain in memory. Refreshes are coalesced per account, including after a 401.
public actor DriveTokenManager {
    private let configuration: DriveOAuthConfiguration
    private let http: DriveHTTP
    private let session: CloudOAuthSession
    public init(
        configuration: DriveOAuthConfiguration, accountID: UUID, credentials: any DriveCredentialStore = CredentialStores.drive(),
        http: DriveHTTP = DriveHTTP()
    ) {
        self.configuration = configuration; self.http = http
        session = CloudOAuthSession(clientID: configuration.clientID, accountID: accountID, credentials: credentials) { refresh in
            var values = ["client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
            values["client_secret"] = configuration.clientSecret
            return try await Self.request(values, configuration: configuration, http: http)
        }
    }
    func accept(_ token: DriveTokenResponse) async throws {
        do { try await session.accept(token) } catch { throw driveOAuthError(error) }
    }
    public func accessToken(rejectedToken: String? = nil) async throws -> String {
        do { return try await session.accessToken(rejectedToken: rejectedToken) } catch { throw driveOAuthError(error) }
    }
    public func requireWriteScope() async throws {
        _ = try await accessToken()
        guard await session.grantedScope?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true else {
            throw DriveError.needsWriteAccess
        }
    }
    func session(_ id: UUID) async throws -> String? { try await session.secret(id) }
    func saveSession(_ value: String, id: UUID) async throws { try await session.saveSecret(value, id: id) }
    func removeSession(_ id: UUID) async throws { try await session.removeSecret(id) }

    /// Always forget local credentials, even if Google's revocation endpoint is unavailable.
    public func revoke() async throws {
        guard let token = try await session.disconnect() else { return }
        var request = URLRequest(url: configuration.revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = DriveHTTP.form(["token": token])
        _ = try await http.data(request)
    }

    static func request(_ values: [String: String], configuration: DriveOAuthConfiguration, http: DriveHTTP) async throws -> DriveTokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = DriveHTTP.form(values)
        let (data, response) = try await http.response(request)
        if response.statusCode == 400 || response.statusCode == 401 { throw DriveError.reconnect }
        try DriveHTTP.check(response.statusCode)
        guard let token = try? JSONDecoder().decode(DriveTokenResponse.self, from: data) else { throw DriveError.invalidResponse }
        return token
    }
}

func driveOAuthError(_ error: Error) -> Error {
    if let error = error as? CloudCredentialError {
        switch error {
        case .keychain(let status): return DriveError.keychain(status);
        case .invalidResponse: return DriveError.invalidResponse
        }
    }
    if error is CloudOAuthSessionError { return DriveError.reconnect }
    guard let error = error as? CloudOAuthError else { return error }
    switch error {
    case .configuration: return DriveError.configuration
    case .state: return DriveError.oauthState
    case .cancelled: return DriveError.oauthCancelled
    case .invalidResponse: return DriveError.invalidResponse
    case .timeout: return DriveError.oauthTimeout
    case .random(let status): return DriveError.keychain(status)
    }
}
