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

public protocol DriveCredentialStore: Sendable {
    func read(clientID: String, accountID: UUID) throws -> String?
    func save(_ token: String, clientID: String, accountID: UUID) throws
    func remove(clientID: String, accountID: UUID) throws
}

/// Test instances (PORPOISE_DEFAULTS_SUITE) against the fake Drive server: the synthetic fixture token is kept in the
/// instance's throwaway defaults, never in the login Keychain, where every rebuilt (ad-hoc signed) binary would make
/// macOS ask the user for access.
public struct DriveTestingCredentials: DriveCredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = Settings.store) { self.defaults = defaults }
    private func key(_ clientID: String, _ accountID: UUID) -> String { "testing.driveCredential.\(clientID).\(accountID.uuidString)" }
    public func read(clientID: String, accountID: UUID) throws -> String? { defaults.string(forKey: key(clientID, accountID)) }
    public func save(_ token: String, clientID: String, accountID: UUID) throws { defaults.set(token, forKey: key(clientID, accountID)) }
    public func remove(clientID: String, accountID: UUID) throws { defaults.removeObject(forKey: key(clientID, accountID)) }
}

public struct DriveKeychainCredentials: DriveCredentialStore, @unchecked Sendable {
    private let keychain: SecKeychain?
    public init() { keychain = nil }
    init(in keychain: SecKeychain) { self.keychain = keychain }
    private func query(_ clientID: String, _ accountID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.porpoise.google-drive.\(clientID)",
            kSecAttrAccount as String: accountID.uuidString,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }
    public func read(clientID: String, accountID: UUID) throws -> String? {
        var q = query(clientID, accountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DriveError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw DriveError.invalidResponse }
        return token
    }
    public func save(_ token: String, clientID: String, accountID: UUID) throws {
        let q = query(clientID, accountID)
        let data = Data(token.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DriveError.keychain(status) }
        var add = q
        add.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain { add[kSecUseKeychain as String] = keychain }
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw DriveError.keychain(added) }
    }
    public func remove(clientID: String, accountID: UUID) throws {
        let status = SecItemDelete(query(clientID, accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveError.keychain(status) }
    }
}

struct DriveTokenResponse: Decodable, Sendable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
    let token_type: String
}

/// A fresh transaction for each sign-in. Only a matching loopback path, state and one code are accepted.
public struct DriveOAuthTransaction: Sendable {
    public let verifier: String
    public let state: String
    public let redirectURL: URL
    public let configuration: DriveOAuthConfiguration

    public init(configuration: DriveOAuthConfiguration, redirectURL: URL) throws {
        guard !configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DriveError.configuration }
        self.configuration = configuration
        self.redirectURL = redirectURL
        verifier = try Self.random()
        state = try Self.random()
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw DriveError.keychain(status) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "=", with: "")
    }

    public var authorizationURL: URL {
        var c = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile https://www.googleapis.com/auth/drive.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    public func code(from callback: URL) throws -> String {
        guard callback.scheme == redirectURL.scheme, callback.host == redirectURL.host,
            callback.port == redirectURL.port, callback.path == redirectURL.path,
            let c = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else { throw DriveError.oauthState }
        let q = c.queryItems ?? []
        guard q.filter({ $0.name == "state" }).count == 1, q.first(where: { $0.name == "state" })?.value == state else { throw DriveError.oauthState }
        if q.contains(where: { $0.name == "error" }) { throw DriveError.oauthCancelled }
        guard q.filter({ $0.name == "code" }).count == 1, let code = q.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw DriveError.invalidResponse
        }
        return code
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
    private let accountID: UUID
    private let credentials: any DriveCredentialStore
    private let http: DriveHTTP
    private var access: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<DriveTokenResponse, Error>?
    private var generation = 0
    private var disconnected = false

    public init(
        configuration: DriveOAuthConfiguration, accountID: UUID, credentials: any DriveCredentialStore = DriveKeychainCredentials(),
        http: DriveHTTP = DriveHTTP()
    ) {
        self.configuration = configuration; self.accountID = accountID; self.credentials = credentials; self.http = http
    }

    func accept(_ token: DriveTokenResponse) throws {
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty, token.expires_in > 0 else { throw DriveError.invalidResponse }
        if let refresh = token.refresh_token, !refresh.isEmpty {
            try credentials.save(refresh, clientID: configuration.clientID, accountID: accountID)
        }
        access = token.access_token
        expiry = Date().addingTimeInterval(token.expires_in)
    }

    public func accessToken(rejectedToken: String? = nil) async throws -> String {
        guard !disconnected else { throw DriveError.reconnect }
        if let access, access != rejectedToken, expiry.timeIntervalSinceNow > 60 { return access }
        if refreshTask == nil {
            guard let refresh = try credentials.read(clientID: configuration.clientID, accountID: accountID) else { throw DriveError.reconnect }
            let configuration = self.configuration, http = self.http
            refreshTask = Task {
                var values = ["client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
                values["client_secret"] = configuration.clientSecret
                return try await Self.request(values, configuration: configuration, http: http)
            }
        }
        let epoch = generation
        do {
            let token = try await refreshTask!.value
            guard !disconnected, generation == epoch else { throw DriveError.reconnect }
            try accept(token)
            refreshTask = nil
            return token.access_token
        } catch {
            if generation == epoch { refreshTask = nil; access = nil }
            throw error
        }
    }

    /// Always forget local credentials, even if Google's revocation endpoint is unavailable.
    public func revoke() async throws {
        generation += 1; disconnected = true
        refreshTask?.cancel(); refreshTask = nil
        let refresh = try credentials.read(clientID: configuration.clientID, accountID: accountID)
        let token = refresh ?? access
        access = nil; expiry = .distantPast
        try credentials.remove(clientID: configuration.clientID, accountID: accountID)
        guard let token else { return }
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
