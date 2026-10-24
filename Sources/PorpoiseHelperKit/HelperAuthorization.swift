import Foundation
import Security

/// The two rights the helper asks for, registered in the authorization database when it's installed. Both ask an
/// administrator to authenticate (Touch ID where the Mac has it, else the password); standard keeps the approval in
/// Porpoise's own authorization for 5 minutes, protected never keeps it.
public enum HelperRights {
    public static let standard = "app.porpoise.helper.standard"
    public static let protected = "app.porpoise.helper.protected"
    public static let standardTimeout = 300

    /// The rule each right must have (the install writes it; the helper refuses to work with any other).
    public static func rule(_ right: String) -> [String: Any] {
        [
            "class": "user", "group": "admin", "authenticate-user": true, "shared": false, "allow-root": false,
            "session-owner": false, "timeout": right == standard ? standardTimeout : 0, "version": 1,
            "comment": right == standard
                ? "Porpoise changes items that belong to the system or other volumes."
                : "Porpoise changes system configuration, startup items, other people's files, ownership or setuid programs.",
        ]
    }

    /// The rule as `security authorizationdb write` reads it.
    public static func plist(_ right: String) -> String {
        let data = try! PropertyListSerialization.data(fromPropertyList: rule(right), format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `installed` (what the database holds for `right`) is at least as strict as `rule(right)`.
    public static func isIntact(_ installed: [String: Any]?, as right: String) -> Bool {
        guard let installed else { return false }
        let expected = rule(right)
        for key in ["class", "group", "authenticate-user", "shared", "allow-root", "session-owner", "timeout"] {
            guard let a = installed[key] as? NSObject, let b = expected[key] as? NSObject, a.isEqual(b) else { return false }
        }
        return true
    }
}

/// What asking for a right came to.
public enum HelperAuthorizationResult: Equatable, Sendable {
    case granted
    /// The person cancelled, or couldn't authenticate.
    case denied
    /// Not an authorization Porpoise made (malformed, or its process is gone).
    case invalid
}

/// Asks the person for a right, on behalf of the authorization Porpoise sent. A seam: tests answer for the system.
public protocol HelperAuthorizing: Sendable {
    func authorize(_ externalForm: Data, right: String, prompt: String) -> HelperAuthorizationResult
    /// Both rights are registered with their own rules (nobody weakened them).
    func rulesIntact() -> Bool
}

/// Authorization Services: the system dialog (Touch ID or password) in the person's session, for Porpoise.
public struct SystemAuthorizer: HelperAuthorizing {
    public init() {}

    public func authorize(_ externalForm: Data, right: String, prompt: String) -> HelperAuthorizationResult {
        guard externalForm.count == kAuthorizationExternalFormLength else { return .invalid }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form.bytes) { externalForm.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &ref) == errAuthorizationSuccess, let ref else { return .invalid }
        defer { AuthorizationFree(ref, []) }
        let status: OSStatus = right.withCString { name in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { text in
                    var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKey, valueLength: strlen(text), value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                    return withUnsafeMutablePointer(to: &item) { ip in
                        withUnsafeMutablePointer(to: &promptItem) { pp in
                            var rights = AuthorizationRights(count: 1, items: ip)
                            var env = AuthorizationEnvironment(count: 1, items: pp)
                            return AuthorizationCopyRights(ref, &rights, &env, [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: return .granted
        case errAuthorizationInvalidRef, errAuthorizationInvalidPointer: return .invalid
        default: return .denied
        }
    }

    public func rulesIntact() -> Bool {
        [HelperRights.standard, HelperRights.protected].allSatisfy { right in
            var dict: CFDictionary?
            guard AuthorizationRightGet(right, &dict) == errAuthorizationSuccess else { return false }
            return HelperRights.isIntact(dict as? [String: Any], as: right)
        }
    }
}
