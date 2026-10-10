import Foundation
import PorpoiseTestSupport
import Security

/// A keychain file of its own, in a scratch folder, deleted with the value. It is not added to the user's search
/// list, so only code handed this keychain sees its items, and nothing reads or writes the login keychain.
final class TestKeychain {
    let keychain: SecKeychain
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch("keychain")
        let password = "porpoise-test"
        var kc: SecKeychain?
        let status = Self.create(scratch.path("test.keychain-db").path, UInt32(password.utf8.count), password, false, nil, &kc)
        guard status == errSecSuccess, let kc else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "SecKeychainCreate: \(status)"])
        }
        keychain = kc
    }

    deinit { _ = Self.delete(keychain) }

    // A keychain file of its own is the only way to keep tests away from the user's keychains, and the functions
    // that make and remove one are deprecated without a replacement. Looked up by name, they build without warnings.
    private typealias Create =
        @convention(c) (
            UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, DarwinBoolean,
            SecAccess?, UnsafeMutablePointer<SecKeychain?>
        ) -> OSStatus
    private typealias Delete = @convention(c) (SecKeychain) -> OSStatus
    private static let create = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainCreate"), to: Create.self)
    private static let delete = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainDelete"), to: Delete.self)

    /// Adds an internet password directly; `protocol` nil makes an item like older versions saved.
    func add(server: String, account: String, password: String, protocol proto: CFString?) {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8),
            kSecUseKeychain as String: keychain,
        ]
        if let proto { q[kSecAttrProtocol as String] = proto }
        SecItemAdd(q as CFDictionary, nil)
    }

    /// The password stored for exactly this protocol.
    func password(server: String, account: String, protocol proto: CFString) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
            kSecAttrAccount as String: account, kSecAttrProtocol as String: proto,
            kSecMatchSearchList as String: [keychain], kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
