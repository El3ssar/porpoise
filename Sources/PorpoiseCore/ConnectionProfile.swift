import Foundation

/// A saved connection: where a server is and how to reach it. It never holds a password or secret key: those are in
/// the Keychain, under the profile (see ConnectionCredentials), so a profile can be stored and shown as it is.
public struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case sftp, ftp, ftps, smb, s3

        public var title: String {
            switch self {
            case .sftp: return "SFTP"
            case .ftp: return "FTP"
            case .ftps: return "FTPS"
            case .smb: return "Windows (SMB)"
            case .s3: return "S3-compatible"
            }
        }

        public var defaultPort: Int? {
            switch self {
            case .sftp: return 22
            case .ftp, .ftps: return 21
            case .smb: return 445
            case .s3: return nil
            }
        }

        /// Whether a password (or S3 secret key) for the profile is kept in the Keychain. SFTP logs in with keys and
        /// the ssh agent; a password ssh asks for is typed in its prompt.
        public var storesSecret: Bool { self != .sftp }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Server name or address; for S3, the bucket's endpoint host is in `endpoint` and this is unused.
    public var host: String
    public var port: Int?
    public var user: String?
    /// The folder the connection opens: absolute ("/srv/www"), or "" for the login folder (SFTP: the home folder).
    /// For SMB, the share and the folder inside it ("Public/Photos").
    public var path: String
    /// SFTP: the ~/.ssh/config Host this profile was made from. ssh then reads that Host's own settings, which win
    /// over nothing set here (only fields the user filled in are passed).
    public var sshAlias: String?
    /// SFTP: jump hosts, outermost first ("user@bastion:2222").
    public var jumpHosts: [String]
    /// SFTP: a private key file to use instead of the agent's and ssh's defaults.
    public var identityFile: String?
    /// S3: bucket, endpoint ("https://s3.eu-west-1.amazonaws.com", "http://127.0.0.1:9000") and region.
    public var bucket: String?
    public var endpoint: String?
    public var region: String?
    /// S3: the access key ID (not secret: the secret key is in the Keychain).
    public var accessKeyID: String?

    public init(
        id: UUID = UUID(), name: String, kind: Kind, host: String = "", port: Int? = nil, user: String? = nil, path: String = "",
        sshAlias: String? = nil, jumpHosts: [String] = [], identityFile: String? = nil, bucket: String? = nil, endpoint: String? = nil,
        region: String? = nil, accessKeyID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.sshAlias = sshAlias
        self.jumpHosts = jumpHosts
        self.identityFile = identityFile
        self.bucket = bucket
        self.endpoint = endpoint
        self.region = region
        self.accessKeyID = accessKeyID
    }

    /// A profile for a ~/.ssh/config Host: ssh resolves the alias itself, so only the alias is the address.
    public init(sshHost h: SSHConfig.Host) {
        self.init(name: h.alias, kind: .sftp, host: h.alias, sshAlias: h.alias, jumpHosts: [])
    }

    // MARK: Address

    /// The name ssh, curl or the Keychain are given for the server: the alias for a ~/.ssh/config Host.
    public var server: String { (sshAlias ?? host).trimmingCharacters(in: .whitespaces) }

    /// What is wrong with the profile, for the editor; nil when it can be connected to.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the connection a name." }
        if let p = port, !(1...65535).contains(p) { return "The port must be between 1 and 65535." }
        if kind == .s3 {
            guard let b = bucket, Self.isBucketName(b) else { return "Enter the bucket name (3–63 lowercase letters, digits, dots or hyphens)." }
            guard let e = endpoint.flatMap(URL.init(string:)), let scheme = e.scheme?.lowercased(), e.host != nil else {
                return "Enter the endpoint address, such as https://s3.amazonaws.com."
            }
            if scheme == "http", !Self.isLoopback(e.host ?? "") { return "Use https for an endpoint that isn't on this Mac." }
            if scheme != "http" && scheme != "https" { return "The endpoint must start with https://." }
            if !(e.path.isEmpty || e.path == "/") || e.query != nil || e.user != nil {
                return "Enter only the endpoint's address, such as https://s3.amazonaws.com (the bucket goes below)."
            }
            if let r = region, r.isEmpty || !r.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                return "The region is a name such as us-east-1."
            }
            return nil
        }
        let s = server
        if s.isEmpty { return "Enter the server name or address." }
        // A server or user starting with "-" would be read as an option by ssh or curl.
        if s.hasPrefix("-") || (user ?? "").hasPrefix("-") { return "The server and user can't start with “-”." }
        if s.contains(where: { $0 == " " || $0 == "/" || $0 == "@" }) { return "The server name can't contain spaces, “/” or “@”." }
        for j in jumpHosts where j.hasPrefix("-") || j.contains(" ") || j.contains(",") {
            return "“\(j)” is not a valid jump host."
        }
        if kind == .smb, path.split(separator: "/").isEmpty { return "Enter the share name." }
        return nil
    }

    /// The location the profile opens, with no password in it.
    public var url: URL? {
        guard problem == nil else { return nil }
        var c = URLComponents()
        if kind == .s3 {
            // S3Location's form: s3://bucket/prefix?endpoint=…&region=…&account=<profile id>.
            c.scheme = "s3"
            c.host = bucket
            let prefix = path.split(separator: "/").joined(separator: "/")
            c.path = prefix.isEmpty ? "/" : "/" + prefix + "/"
            c.queryItems = [
                URLQueryItem(name: "endpoint", value: endpoint), URLQueryItem(name: "region", value: region ?? "us-east-1"),
                URLQueryItem(name: "account", value: id.uuidString.lowercased()),
            ]
            // URLComponents leaves "/" and ":" alone in a query; S3Location expects the endpoint fully encoded.
            c.percentEncodedQuery = c.queryItems?.map {
                "\($0.name)=\($0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? "")"
            }.joined(separator: "&")
            return c.url
        }
        c.scheme = kind.rawValue
        c.host = server
        if let p = port, p != kind.defaultPort || sshAlias != nil { c.port = p }
        if let u = user?.trimmingCharacters(in: .whitespaces), !u.isEmpty { c.user = u }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .sftp:
            // An empty or relative folder is in the home folder, which SSHProvider writes "/~/".
            if trimmed.isEmpty { c.path = "/~/" } else if trimmed.hasPrefix("/") { c.path = trimmed } else { c.path = "/~/" + trimmed }
        default:
            c.path = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        }
        return c.url
    }

    /// Whether `url` is in this profile's server: same scheme, server, user and port (default port when unset).
    public func covers(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if kind == .s3 {
            return scheme == "s3" && url.host == bucket
                && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "account" })?.value?
                    .lowercased() == id.uuidString.lowercased()
        }
        let schemes: Set<String> = kind == .sftp ? ["sftp", "ssh", "scp", "fish"] : [kind.rawValue]
        guard schemes.contains(scheme), url.host?.lowercased() == server.lowercased() else { return false }
        let urlUser = url.user(percentEncoded: false) ?? ""
        let ownUser = user?.trimmingCharacters(in: .whitespaces) ?? ""
        guard urlUser == ownUser else { return false }
        return (url.port ?? kind.defaultPort) == (port ?? kind.defaultPort)
    }

    /// A one-line address for lists: "user@host:2222", "bucket on s3.example.com".
    public var address: String {
        if kind == .s3 { return "\(bucket ?? "?") on \(endpoint.flatMap { URL(string: $0)?.host } ?? "?")" }
        var s = server
        if let u = user, !u.isEmpty { s = u + "@" + s }
        if let p = port, p != kind.defaultPort { s += ":\(p)" }
        if !jumpHosts.isEmpty { s += " via " + jumpHosts.joined(separator: " → ") }
        return s
    }

    static func isBucketName(_ s: String) -> Bool {
        (3...63).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
            && (s.first.map { $0.isLetter || $0.isNumber } ?? false)
    }

    static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) }

    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
