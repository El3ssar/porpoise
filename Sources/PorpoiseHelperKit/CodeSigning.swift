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

    /// The same check for the process that sent `auditToken` (an audit token names one process for good, where a
    /// process number can be reused).
    public static func isIntact(auditToken: Data, requirement: String) -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code) == errSecSuccess,
            let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return false }
        return isIntact(staticCode, requirement: requirement)
    }

    /// Whether the helper takes a connection: from a process it can name by audit token (none: refused), whose
    /// program on disk is intact and signed as `requirement` says.
    public static func accepts(auditToken: Data?, requirement: String?, isIntact: (Data, String) -> Bool = isIntact) -> Bool {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size, let requirement else { return false }
        return isIntact(auditToken, requirement)
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
        // Single-threaded: otherwise Security checks nested code on dispatch's shared threads and waits for them, which
        // never finishes when every such thread is itself waiting here (a busy test run on a 3-core machine did).
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSSingleThreaded)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
