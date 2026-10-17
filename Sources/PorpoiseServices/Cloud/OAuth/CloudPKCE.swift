import CryptoKit
import Foundation
import Security

public enum CloudOAuthError: Error { case configuration, state, cancelled, invalidResponse, timeout, random(Int32) }
public protocol CloudCredentialStore: Sendable {
    func read(clientID: String, accountID: UUID) throws -> String?
    func save(_ token: String, clientID: String, accountID: UUID) throws
    func remove(clientID: String, accountID: UUID) throws
}

/// Common S256/state/redirect validation. Provider-specific scopes and consent options are explicit parameters.
public struct CloudPKCE: Sendable {
    public let verifier: String
    public let state: String
    public let redirectURL: URL
    public init(clientID: String, redirectURL: URL) throws {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudOAuthError.configuration }
        self.redirectURL = redirectURL
        verifier = try Self.random(); state = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CloudOAuthError.random(status) }
        return base64URL(Data(bytes))
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "=", with: "")
    }
    public func authorizationURL(_ endpoint: URL, clientID: String, parameters: [URLQueryItem]) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems =
            [
                URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
                URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ] + parameters
        return components.url!
    }
    public func code(from callback: URL) throws -> String {
        guard callback.scheme == redirectURL.scheme, callback.host == redirectURL.host, callback.port == redirectURL.port,
            callback.path == redirectURL.path, callback.user == nil, callback.password == nil, callback.fragment == nil,
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else { throw CloudOAuthError.state }
        let query = components.queryItems ?? []
        guard query.filter({ $0.name == "state" }).count == 1, query.first(where: { $0.name == "state" })?.value == state else {
            throw CloudOAuthError.state
        }
        if query.contains(where: { $0.name == "error" }) { throw CloudOAuthError.cancelled }
        guard query.filter({ $0.name == "code" }).count == 1, let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw CloudOAuthError.invalidResponse
        }
        return code
    }
}
