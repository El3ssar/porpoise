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

    /// Whether the program that process `pid` runs is, on disk, signed as `requirement` says and unchanged since,
    /// with everything in its bundle (frameworks included). Porpoise loads frameworks without library validation
    /// (they carry no Team ID), so a running Porpoise satisfying its requirement doesn't prove that what it loaded is
    /// Porpoise's own: a framework swapped inside the app would run as Porpoise. Its bundle's seal covers them.
    public static func isIntact(pid: pid_t, requirement: String) -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return false }
        return isIntact(staticCode, requirement: requirement)
    }

    /// Whether the bundle or program at `url` is signed as `requirement` says and unchanged, nested code included.
    public static func isIntact(at url: URL, requirement: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return isIntact(staticCode, requirement: requirement)
    }

    private static func isIntact(_ code: SecStaticCode, requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
