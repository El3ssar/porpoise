import Foundation
import PorpoiseCore

public struct DropboxConfiguration: Sendable {
    public var appKey: String
    public var isConfigured: Bool { !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Dropbox requires an exactly registered redirect URI; zero is reserved for loopback fixtures.
    public var loopbackPort: UInt16
    public static let registeredLoopbackPort: UInt16 = 61843
    public var loopbackPorts: [UInt16] {
        loopbackPort == 0 ? [0] : (0...2).compactMap { UInt16(exactly: Int(loopbackPort) + $0) }
    }
    public func makeLoopbackListener() throws -> CloudOAuthLoopback { try makeLoopbackListener(bind: CloudOAuthLoopback.init(port:)) }
    /// The first of `loopbackPorts` that `bind` takes, in order; all busy: `portsBusy`.
    func makeLoopbackListener<Listener>(bind: (UInt16) throws -> Listener) throws -> Listener {
        for port in loopbackPorts {
            do { return try bind(port) } catch is CloudOAuthLoopback.PortInUse { continue }
        }
        throw DropboxCallbackError.portsBusy(loopbackPorts)
    }
    public var authorizationURL: URL
    public var tokenURL: URL
    public var apiURL: URL
    public var contentURL: URL
    public var notifyURL: URL
    public init(
        appKey: String, loopbackPort: UInt16 = registeredLoopbackPort,
        authorizationURL: URL = URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenURL: URL = URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        apiURL: URL = URL(string: "https://api.dropboxapi.com/2/")!,
        contentURL: URL = URL(string: "https://content.dropboxapi.com/2/")!,
        notifyURL: URL = URL(string: "https://notify.dropboxapi.com/2/")!
    ) {
        self.appKey = appKey; self.loopbackPort = loopbackPort; self.authorizationURL = authorizationURL; self.tokenURL = tokenURL
        self.apiURL = apiURL; self.contentURL = contentURL; self.notifyURL = notifyURL
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
            // The environment is for test instances only; the setting is the user's own app key (Settings › Accounts).
            appKey: nonempty(testing ? TestEnvironment.dropboxAppKey.value(in: environment) : nil)
                ?? nonempty(defaults.string(forKey: "dropboxAppKey"))
                ?? nonempty(bundle.object(forInfoDictionaryKey: "DropboxAppKey") as? String) ?? "")
    }
    public static let scopes = "files.metadata.read files.metadata.write files.content.read files.content.write account_info.read sharing.read"
}

public enum DropboxCallbackError: Error, Equatable, LocalizedError {
    case portsBusy([UInt16])
    public var errorDescription: String? {
        switch self {
        case .portsBusy(let ports):
            return
                "Dropbox sign-in couldn’t start because local ports \(ports.map(String.init).joined(separator: ", ")) are in use. Close other sign-in windows or apps using these ports, then try again."
        }
    }
}

public struct DropboxOAuthTransaction: Sendable {
    public let pkce: CloudPKCE
    public let configuration: DropboxConfiguration
    public init(configuration: DropboxConfiguration, redirectURL: URL) throws {
        self.configuration = configuration; pkce = try CloudPKCE(clientID: configuration.appKey, redirectURL: redirectURL)
    }
    public var authorizationURL: URL {
        pkce.authorizationURL(
            configuration.authorizationURL, clientID: configuration.appKey,
            parameters: [.init(name: "token_access_type", value: "offline"), .init(name: "scope", value: DropboxConfiguration.scopes)])
    }
    public func exchange(_ callback: URL, http: CloudHTTPTransport = .init()) async throws -> CloudOAuthToken {
        try await DropboxTokens.request(
            [
                "client_id": configuration.appKey, "code": pkce.code(from: callback),
                "redirect_uri": pkce.redirectURL.absoluteString, "code_verifier": pkce.verifier,
                "grant_type": "authorization_code",
            ], configuration: configuration, http: http)
    }
}

public enum DropboxTokens {
    public static func session(
        configuration: DropboxConfiguration, accountID: UUID,
        credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "dropbox"),
        http: CloudHTTPTransport = .init()
    ) -> CloudOAuthSession {
        CloudOAuthSession(clientID: configuration.appKey, accountID: accountID, credentials: credentials) { refresh in
            try await request(
                ["client_id": configuration.appKey, "refresh_token": refresh, "grant_type": "refresh_token"], configuration: configuration, http: http
            )
        }
    }
    /// Ends the sign-in at Dropbox too: revoking an access token also revokes its refresh token. Best effort; the
    /// credentials are forgotten here whatever Dropbox answers.
    static func revoke(_ access: String, configuration: DropboxConfiguration, http: CloudHTTPTransport) async {
        var request = URLRequest(url: configuration.apiURL.appendingPathComponent("auth/token/revoke"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("null".utf8)
        _ = try? await http.response(request)
    }

    static func request(_ values: [String: String], configuration: DropboxConfiguration, http: CloudHTTPTransport) async throws -> CloudOAuthToken {
        let (data, response) = try await http.postForm(configuration.tokenURL, values)
        guard response.statusCode != 400, response.statusCode != 401 else { throw DropboxError.reconnect }
        try DropboxClient.check(data, response)
        return try JSONDecoder().decode(CloudOAuthToken.self, from: data)
    }
}
