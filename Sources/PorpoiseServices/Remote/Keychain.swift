import Foundation
import Security

/// Internet passwords keyed by server, account and protocol: a NAS's SMB password that Finder saved must never be
/// sent over FTP, nor be overwritten by it. Items saved without a protocol (older versions) are still found.
/// `keychain` is the user's default keychains when nil; tests pass a throwaway one.
enum Keychain {
    private static func proto(_ scheme: String) -> CFString { scheme == "ftps" ? kSecAttrProtocolFTPS : kSecAttrProtocolFTP }

    static func password(server: String, account: String, scheme: String, in keychain: SecKeychain? = nil) -> String? {
        var base: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
                                   kSecAttrAccount as String: account]
        if let keychain { base[kSecMatchSearchList as String] = [keychain] }
        func data(_ q: [String: Any]) -> String? {
            var out: AnyObject?
            var q = q
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        var exact = base
        exact[kSecAttrProtocol as String] = proto(scheme)
        if let p = data(exact) { return p }
        // An item without a protocol (saved by an older version): found by its reference, never another protocol's.
        var list = base
        list[kSecReturnAttributes as String] = true
        list[kSecReturnPersistentRef as String] = true
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]],
              let ref = items.first(where: { $0[kSecAttrProtocol as String] == nil })?[kSecValuePersistentRef as String] else { return nil }
        var byRef: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecValuePersistentRef as String: ref]
        if let keychain { byRef[kSecMatchSearchList as String] = [keychain] }
        return data(byRef)
    }

    static func save(server: String, account: String, password: String, scheme: String, in keychain: SecKeychain? = nil) {
        var q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
                                kSecAttrAccount as String: account, kSecAttrProtocol as String: proto(scheme)]
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        let data = Data(password.utf8)
        // Update in place keeps the item's access settings; add only when there is none yet.
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var add = q
        add.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain { add[kSecUseKeychain as String] = keychain }
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Porpoise: \(scheme)://\(account)@\(server)"
        SecItemAdd(add as CFDictionary, nil)
    }
}
