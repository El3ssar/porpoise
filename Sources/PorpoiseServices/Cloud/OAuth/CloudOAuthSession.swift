import Foundation

public struct CloudOAuthToken: Decodable, Sendable {
    public let access_token: String
    public let expires_in: Double
    public let refresh_token: String?
    public let token_type: String
    public var scope: String? = nil
}
public enum CloudOAuthSessionError: Error { case reconnect }

/// Coalesced refresh and sign-out fencing. Refresh tokens/session secrets use the injected credential store only.
public actor CloudOAuthSession {
    private let clientID: String
    private let accountID: UUID
    private let credentials: any CloudCredentialStore
    private let refresh: @Sendable (String) async throws -> CloudOAuthToken
    private var access: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<CloudOAuthToken, Error>?
    private var generation = 0
    private var disconnected = false
    public private(set) var grantedScope: String?
    public init(
        clientID: String, accountID: UUID, credentials: any CloudCredentialStore,
        refresh: @escaping @Sendable (String) async throws -> CloudOAuthToken
    ) {
        self.clientID = clientID; self.accountID = accountID; self.credentials = credentials; self.refresh = refresh
    }
    public func accept(_ token: CloudOAuthToken) throws {
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty, token.expires_in > 0 else {
            throw CloudOAuthError.invalidResponse
        }
        if let refresh = token.refresh_token, !refresh.isEmpty { try credentials.save(refresh, clientID: clientID, accountID: accountID) }
        if let scope = token.scope { grantedScope = scope }
        access = token.access_token; expiry = Date().addingTimeInterval(token.expires_in)
    }
    public func accessToken(rejectedToken: String? = nil) async throws -> String {
        guard !disconnected else { throw CloudOAuthSessionError.reconnect }
        if let access, access != rejectedToken, expiry.timeIntervalSinceNow > 60 { return access }
        if refreshTask == nil {
            guard let token = try credentials.read(clientID: clientID, accountID: accountID) else { throw CloudOAuthSessionError.reconnect }
            let refresh = self.refresh
            refreshTask = Task { try await refresh(token) }
        }
        let epoch = generation
        do {
            let token = try await refreshTask!.value
            guard !disconnected, generation == epoch else { throw CloudOAuthSessionError.reconnect }
            try accept(token); refreshTask = nil
            return token.access_token
        } catch {
            if generation == epoch { refreshTask = nil; access = nil }
            throw error
        }
    }
    public func secret(_ id: UUID) throws -> String? { try credentials.read(clientID: clientID + ".upload-session", accountID: id) }
    public func saveSecret(_ value: String, id: UUID) throws { try credentials.save(value, clientID: clientID + ".upload-session", accountID: id) }
    public func removeSecret(_ id: UUID) throws { try credentials.remove(clientID: clientID + ".upload-session", accountID: id) }
    /// Forget locally before a provider's optional network revoke. A late refresh cannot re-save credentials.
    public func disconnect() throws -> String? {
        generation += 1; disconnected = true
        refreshTask?.cancel(); refreshTask = nil
        let token = try credentials.read(clientID: clientID, accountID: accountID) ?? access
        access = nil; expiry = .distantPast
        try credentials.remove(clientID: clientID, accountID: accountID)
        return token
    }
}
