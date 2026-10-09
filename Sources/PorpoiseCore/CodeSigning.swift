import CryptoKit
import Foundation
import Security

public enum CodeSigning {
    /// SHA-1 of the certificate this process is signed with (nil when unsigned or ad hoc).
    public static func ownLeafCertificateHash() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first
        else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// A code requirement for `identifier` signed with this process's own certificate.
    public static func requirement(identifier: String) -> String? {
        ownLeafCertificateHash().map { "identifier \"\(identifier)\" and certificate leaf = H\"\($0)\"" }
    }
}
