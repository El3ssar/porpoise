import Foundation
import Security

/// Internet passwords keyed by server, account and protocol: a NAS's SMB password that Finder saved must never be
/// sent over FTP, nor be overwritten by it. Items saved without a protocol (older versions) are still found.
/// Only the central credential factory selects this system implementation.
struct Keychain: PasswordCredentialStore {
    let api: any KeychainAPI
    init(api: any KeychainAPI = SystemKeychainAPI()) { self.api = api }
    private static func proto(_ scheme: String) -> CFString { scheme == "ftps" ? kSecAttrProtocolFTPS : kSecAttrProtocolFTP }

    func password(server: String, account: String, scheme: String) -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
        ]
        func data(_ q: [String: Any]) -> String? {
            var q = q
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, out) = api.copy(q)
            guard status == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        var exact = base
        exact[kSecAttrProtocol as String] = Self.proto(scheme)
        if let p = data(exact) { return p }
        // An item without a protocol (saved by an older version): found by its reference, never another protocol's.
        var list = base
        list[kSecReturnAttributes as String] = true
        list[kSecReturnPersistentRef as String] = true
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, out) = api.copy(list)
        guard status == errSecSuccess, let items = out as? [[String: Any]],
            let ref = items.first(where: { $0[kSecAttrProtocol as String] == nil })?[kSecValuePersistentRef as String]
        else { return nil }
        let byRef: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecValuePersistentRef as String: ref]
        return data(byRef)
    }

    func save(server: String, account: String, password: String, scheme: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account, kSecAttrProtocol as String: Self.proto(scheme),
        ]
        let data = Data(password.utf8)
        // Update in place keeps the item's access settings; add only when there is none yet.
        if api.update(q, attributes: [kSecValueData as String: data]) == errSecSuccess { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Porpoise: \(scheme)://\(account)@\(server)"
        _ = api.add(add)
    }
}
