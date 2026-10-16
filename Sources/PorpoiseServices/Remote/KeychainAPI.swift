import Foundation
import Security

/// The Security boundary is injectable so query construction and legacy migration are tested without
/// touching any keychain. Every real API entry checks isolation before invoking Security.framework.
protocol KeychainAPI: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainAPI: KeychainAPI {
    func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        CredentialStores.requireSystemAccess()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        CredentialStores.requireSystemAccess()
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        CredentialStores.requireSystemAccess()
        return SecItemAdd(query as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        CredentialStores.requireSystemAccess()
        return SecItemDelete(query as CFDictionary)
    }
}
