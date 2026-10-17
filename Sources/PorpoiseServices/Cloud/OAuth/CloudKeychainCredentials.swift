import Foundation
import Security

public enum CloudCredentialError: Error { case keychain(Int32), invalidResponse }

public struct CloudKeychainCredentials: CloudCredentialStore, @unchecked Sendable {
    private let api: any KeychainAPI
    private let providerID: String
    public init(providerID: String) { self.providerID = providerID; api = SystemKeychainAPI() }
    init(providerID: String, api: any KeychainAPI) { self.providerID = providerID; self.api = api }
    private func query(_ clientID: String, _ accountID: UUID) -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.porpoise.\(providerID).\(clientID)",
            kSecAttrAccount as String: accountID.uuidString,
        ]
        return query
    }
    public func read(clientID: String, accountID: UUID) throws -> String? {
        var q = query(clientID, accountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = api.copy(q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudCredentialError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw CloudCredentialError.invalidResponse }
        return token
    }
    public func save(_ token: String, clientID: String, accountID: UUID) throws {
        let q = query(clientID, accountID)
        let data = Data(token.utf8)
        let status = api.update(q, attributes: [kSecValueData as String: data])
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CloudCredentialError.keychain(status) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = api.add(add)
        guard added == errSecSuccess else { throw CloudCredentialError.keychain(added) }
    }
    public func remove(clientID: String, accountID: UUID) throws {
        let status = api.delete(query(clientID, accountID))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudCredentialError.keychain(status) }
    }
}
