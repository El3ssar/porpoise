import Foundation

/// The user's Box application registration secret shares the credential-store isolation policy used by tokens.
public enum BoxApplicationSecret {
    private static let account = UUID(uuidString: "C1CC795E-6941-4A19-A8F3-B171BA7A44E9")!
    private static let lock = NSLock()
    private static var generation: UInt64 = 0
    public static var revision: UInt64 { lock.withLock { generation } }
    public static func read(
        defaults: UserDefaults = Settings.store,
        credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "box-application")
    ) throws -> String? {
        let client = (defaults.string(forKey: "boxClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { return nil }
        if let legacy = defaults.string(forKey: "boxClientSecret") {
            try credentials.save(legacy, clientID: client, accountID: account)
            defaults.removeObject(forKey: "boxClientSecret")
            lock.withLock { generation &+= 1 }
            return legacy
        }
        return try credentials.read(clientID: client, accountID: account)
    }
    public static func save(
        _ value: String, defaults: UserDefaults = Settings.store,
        credentials: any CloudCredentialStore = CredentialStores.cloud(providerID: "box-application")
    ) throws {
        let client = (defaults.string(forKey: "boxClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { throw CloudOAuthError.configuration }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            try credentials.remove(clientID: client, accountID: account)
        } else {
            try credentials.save(value, clientID: client, accountID: account)
        }
        defaults.removeObject(forKey: "boxClientSecret")
        lock.withLock { generation &+= 1 }
    }
}
