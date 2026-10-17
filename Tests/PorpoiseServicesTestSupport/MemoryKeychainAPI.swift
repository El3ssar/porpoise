import Foundation
import PorpoiseTestSupport
import Security

@testable import PorpoiseServices

/// Security query emulator: never creates, unlocks or accesses a keychain file.
public final class MemoryKeychainAPI: KeychainAPI, @unchecked Sendable {
    public var items: [[String: Any]] = []
    public var failure: OSStatus?
    public var invalidData = false
    public init() {}
    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        let keys = [kSecClass, kSecAttrServer, kSecAttrAccount, kSecAttrProtocol, kSecAttrService, kSecValuePersistentRef]
        return keys.allSatisfy { key in
            guard let wanted = query[key as String] else { return true }
            return (item[key as String] as? NSObject)?.isEqual(wanted) == true
        }
    }
    public func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        if let failure { return (failure, nil) }
        let found = items.filter { matches($0, query) }
        guard let first = found.first else { return (errSecItemNotFound, nil) }
        if query[kSecReturnAttributes as String] as? Bool == true { return (errSecSuccess, found as NSArray) }
        return (errSecSuccess, invalidData ? NSNumber(value: 1) : first[kSecValueData as String] as AnyObject?)
    }
    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let failure { return failure }
        guard let index = items.firstIndex(where: { matches($0, query) }) else { return errSecItemNotFound }
        items[index].merge(attributes) { _, new in new }
        return errSecSuccess
    }
    public func add(_ query: [String: Any]) -> OSStatus {
        if let failure { return failure }
        var item = query
        item[kSecValuePersistentRef as String] = Data(UUID().uuidString.utf8)
        items.append(item)
        return errSecSuccess
    }
    public func delete(_ query: [String: Any]) -> OSStatus {
        if let failure { return failure }
        items.removeAll { matches($0, query) }
        return errSecSuccess
    }
    public func password(server: String, account: String, scheme: String) -> String? {
        let (_, result) = copy([
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: scheme == "smb" ? kSecAttrProtocolSMB : kSecAttrProtocolFTP,
        ])
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    public func add(server: String, account: String, password: String, scheme: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8),
        ]
        if let scheme {
            query[kSecAttrProtocol as String] = scheme == "smb" ? kSecAttrProtocolSMB : kSecAttrProtocolFTP
        }
        _ = add(query)
    }
}
