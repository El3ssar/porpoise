import Foundation

protocol PasswordCredentialStore: Sendable {
    func password(server: String, account: String, scheme: String) -> String?
    func save(server: String, account: String, password: String, scheme: String)
}

/// One policy for FTP passwords and Drive refresh tokens. Test detection does not depend on a suite's
/// setup hook running before a default argument or singleton is evaluated.
public enum CredentialStores {
    static func isolated(environment: [String: String], arguments: [String], testing: Bool) -> Bool {
        testing || environment["PORPOISE_DEFAULTS_SUITE"] != nil || environment["PORPOISE_BRIDGE"] != nil
            || environment["XCTestConfigurationFilePath"] != nil || environment["SWIFT_TESTING_ENABLED"] != nil
            || arguments.contains { $0.contains(".xctest") || $0.contains("swiftpm-testing-helper") }
    }

    public static var isIsolated: Bool {
        NSClassFromString("XCTestCase") != nil
            || isolated(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments, testing: Settings.isTesting)
    }

    static func requireSystemAccess() {
        precondition(!isIsolated, "Isolated/test processes must never access the system Keychain")
    }

    private static let memory = MemoryCredentials()
    public static func drive() -> any DriveCredentialStore { drive(isolated: isIsolated) }
    static func drive(isolated: Bool) -> any DriveCredentialStore { isolated ? memory : DriveKeychainCredentials() }
    static func passwords() -> any PasswordCredentialStore { isIsolated ? memory : Keychain() }
}

/// Process-local credentials for tests and review apps. Synthetic tokens never reach the login Keychain;
/// keeping them in memory also avoids persisting real tokens in defaults.
public final class MemoryCredentials: DriveCredentialStore, PasswordCredentialStore, @unchecked Sendable {
    private enum Key: Hashable {
        case internet(String, String, String?)
        case drive(String, UUID)
    }
    private let lock = NSLock()
    private var values: [Key: String] = [:]
    public init() {}

    private func read(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    private func set(_ value: String?, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
    func password(server: String, account: String, scheme: String) -> String? {
        read(.internet(server, account, scheme)) ?? read(.internet(server, account, nil))
    }
    func save(server: String, account: String, password: String, scheme: String) {
        set(password, for: .internet(server, account, scheme))
    }
    /// Seed a legacy password without a protocol, or another protocol, in a test fixture.
    func add(server: String, account: String, password: String, scheme: String?) {
        set(password, for: .internet(server, account, scheme))
    }
    public func read(clientID: String, accountID: UUID) throws -> String? { read(.drive(clientID, accountID)) }
    public func save(_ token: String, clientID: String, accountID: UUID) throws { set(token, for: .drive(clientID, accountID)) }
    public func remove(clientID: String, accountID: UUID) throws { set(nil, for: .drive(clientID, accountID)) }
}
