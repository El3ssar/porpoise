import Foundation

/// A bucket and exact object key. Endpoint, region and credential identity survive URL path operations.
public struct S3Location: Equatable, Sendable {
    public let bucket: String
    public let key: String
    public let endpoint: URL
    public let region: String
    public let accountID: UUID
    public init(bucket: String, key: String = "", endpoint: URL? = nil, region: String = "us-east-1", accountID: UUID) {
        self.bucket = bucket; self.key = key; self.region = region; self.accountID = accountID
        self.endpoint = endpoint ?? URL(string: "https://s3.\(region).amazonaws.com")!
    }
    public init?(url: URL) {
        guard url.scheme == "s3", let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let bucket = c.host,
            !bucket.isEmpty, c.user == nil, c.password == nil, c.port == nil, c.fragment == nil
        else { return nil }
        let q = c.queryItems ?? []
        guard Set(q.map(\.name)).count == q.count, q.allSatisfy({ ["endpoint", "region", "account"].contains($0.name) }),
            let account = q.first(where: { $0.name == "account" })?.value.flatMap(UUID.init(uuidString:))
        else { return nil }
        let region = q.first(where: { $0.name == "region" })?.value ?? "us-east-1"
        guard !region.isEmpty, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let endpoint: URL
        if let text = q.first(where: { $0.name == "endpoint" })?.value {
            guard let u = URL(string: text), let ec = URLComponents(url: u, resolvingAgainstBaseURL: false),
                ec.host != nil, ec.user == nil, ec.password == nil, ec.query == nil, ec.fragment == nil,
                ec.path.isEmpty || ec.path == "/",
                ec.scheme == "https" || (ec.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(ec.host!))
            else { return nil }
            endpoint = u
        } else {
            endpoint = URL(string: "https://s3.\(region).amazonaws.com")!
        }
        self.init(bucket: bucket, key: String(c.path.dropFirst()), endpoint: endpoint, region: region, accountID: account)
    }
    public var url: URL {
        var c = URLComponents(); c.scheme = "s3"; c.host = bucket; c.path = "/" + key
        c.queryItems = [
            .init(name: "endpoint", value: endpoint.absoluteString), .init(name: "region", value: region),
            .init(name: "account", value: accountID.uuidString.lowercased()),
        ]
        return c.url!
    }
    public func replacingKey(_ key: String) -> Self { .init(bucket: bucket, key: key, endpoint: endpoint, region: region, accountID: accountID) }
    var prefix: String { key.isEmpty || key.hasSuffix("/") ? key : key + "/" }
}

public struct S3AccessKeys: Codable, Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.sessionToken = sessionToken
    }
}

/// Uses the shared isolated-memory/production-Keychain policy. URLs and settings contain only account UUIDs.
public enum S3Credentials {
    public static func save(_ keys: S3AccessKeys, accountID: UUID) throws {
        let text = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        try CredentialStores.cloud(providerID: "s3").save(text, clientID: "access-keys", accountID: accountID)
    }
    public static func read(accountID: UUID) throws -> S3AccessKeys {
        guard let text = try CredentialStores.cloud(providerID: "s3").read(clientID: "access-keys", accountID: accountID) else {
            throw S3Error.credentials
        }
        return try JSONDecoder().decode(S3AccessKeys.self, from: Data(text.utf8))
    }
    public static func remove(accountID: UUID) throws {
        try CredentialStores.cloud(providerID: "s3").remove(clientID: "access-keys", accountID: accountID)
    }
}

public enum S3Error: LocalizedError {
    case invalidLocation, invalidResponse, credentials, changed, service(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidLocation: return "Invalid S3 location."
        case .invalidResponse: return "Invalid S3 response."
        case .credentials: return "Connect this S3 account with its access keys."
        case .changed: return "The S3 object or local source changed during the transfer."
        case .service(let status, let code): return "S3 error \(status): \(code)"
        }
    }
}
