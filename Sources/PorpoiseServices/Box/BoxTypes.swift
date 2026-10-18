import Foundation
import PorpoiseCore

public enum BoxError: Error, Equatable, LocalizedError {
    case invalidResponse, invalidLocation, reconnect, offline, conflict, notFound, sourceChanged, uncertain, unsupportedUndo, http(Int), api(
        Int, String), offset(Int64)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Box returned an invalid response."
        case .invalidLocation: return "This Box location is invalid."
        case .reconnect: return "Sign in to Box again."
        case .offline: return "Box is offline."
        case .conflict: return "The destination exists or the file changed."
        case .notFound: return "This Box item no longer exists."
        case .sourceChanged: return "The source changed during the transfer."
        case .uncertain: return "Box may have applied this change. Review it before trying again."
        case .unsupportedUndo: return "Box cannot safely undo this change."
        case .http(let status), .api(let status, _): return "Box request failed (\(status))."
        case .offset: return "Box upload offset changed."
        }
    }
}

/// A Box file, folder or web link. IDs are opaque and never reconstructed from names or paths; the root folder is "0".
/// https://developer.box.com/reference/resources/file/ and /resources/folder/
public struct BoxItem: CloudMetadataItem, Equatable {
    public enum Kind: String, Codable, Sendable { case file, folder, webLink = "web_link" }
    public var id: String
    public var kind: Kind
    public var name: String
    public var parentID: String?
    /// Changes with every change to the item, a rename included: the precondition for changing it (If-Match).
    public var etag: String?
    /// The current version's ID: changes with the bytes only.
    public var versionID: String?
    public var size: Int64?
    public var sha1: String?
    public var modified: String?
    /// active, trashed or deleted.
    public var status: String?
    public init(
        id: String, name: String, kind: Kind = .file, parentID: String? = nil, etag: String? = nil, versionID: String? = nil, size: Int64? = nil,
        sha1: String? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.parentID = parentID; self.etag = etag; self.versionID = versionID
        self.size = size; self.sha1 = sha1
    }
    public var isFolder: Bool { kind == .folder }
    public var isRoot: Bool { kind == .folder && id == BoxItem.rootID }
    public var isDeleted: Bool { status != nil && status != "active" }
    /// The content revision: the version ID (a rename keeps it); the etag where there's none.
    public var revision: String? { kind == .file ? versionID ?? etag : etag }
    public var canDownload: Bool { kind == .file && !isDeleted }
    public static let rootID = "0"

    private enum Keys: String, CodingKey {
        case id, type, name, etag, size, sha1, parent
        case version = "file_version", modified = "modified_at", status = "item_status"
    }
    private enum RefKeys: String, CodingKey { case id, type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty, let kind = Kind(rawValue: try c.decode(String.self, forKey: .type)) else { throw BoxError.invalidResponse }
        self.kind = kind
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        sha1 = try c.decodeIfPresent(String.self, forKey: .sha1)
        modified = try c.decodeIfPresent(String.self, forKey: .modified)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        if let version = try? c.nestedContainer(keyedBy: RefKeys.self, forKey: .version) {
            versionID = try version.decodeIfPresent(String.self, forKey: .id)
        }
        if let parent = try? c.nestedContainer(keyedBy: RefKeys.self, forKey: .parent) {
            parentID = try parent.decodeIfPresent(String.self, forKey: .id)
        }
    }
    /// Written in Box's own shape, so a cached item reads back exactly as it was received.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(kind.rawValue, forKey: .type); try c.encode(name, forKey: .name)
        try c.encodeIfPresent(etag, forKey: .etag); try c.encodeIfPresent(size, forKey: .size); try c.encodeIfPresent(sha1, forKey: .sha1)
        try c.encodeIfPresent(modified, forKey: .modified); try c.encodeIfPresent(status, forKey: .status)
        if let versionID {
            var version = c.nestedContainer(keyedBy: RefKeys.self, forKey: .version)
            try version.encode(versionID, forKey: .id); try version.encode("file_version", forKey: .type)
        }
        if let parentID {
            var parent = c.nestedContainer(keyedBy: RefKeys.self, forKey: .parent)
            try parent.encode(parentID, forKey: .id); try parent.encode("folder", forKey: .type)
        }
    }
    public var location: (itemID: String, kind: Kind) { (isRoot ? "" : id, kind) }
    public func fileItem(accountID: UUID) -> FileItem {
        FileItem(url: BoxLocation(accountID: accountID, itemID: location.itemID, kind: kind).url, name: name, isDirectory: isFolder, size: size ?? 0)
    }
}

public struct BoxAccount: Codable, Equatable, Sendable {
    public var id: UUID
    /// Box's user ID: the same person signing in again has the same one.
    public var userID: String
    public var email: String
    public var displayName: String
}

/// `box://<account>/<item ID>?type=<file|folder|web_link>`: one encoded segment holds the whole opaque ID, and the type
/// says which API family names it (Box has no endpoint for an item of unknown type). An empty item is the root folder.
public struct BoxLocation: Equatable, Sendable {
    public let accountID: UUID
    public let itemID: String
    public let kind: BoxItem.Kind?
    public init(accountID: UUID, itemID: String = "", kind: BoxItem.Kind? = nil) {
        self.accountID = accountID; self.itemID = itemID; self.kind = itemID.isEmpty ? .folder : kind
    }
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "box", let host = c.host,
            let account = UUID(uuidString: host), c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
            (c.queryItems ?? []).count <= 1, (c.queryItems ?? []).allSatisfy({ $0.name == "type" && BoxItem.Kind(rawValue: $0.value ?? "") != nil }),
            c.percentEncodedPath.hasPrefix("/"), let item = String(c.percentEncodedPath.dropFirst()).removingPercentEncoding,
            !String(c.percentEncodedPath.dropFirst()).contains("/"), item != BoxItem.rootID
        else { return nil }
        self.init(accountID: account, itemID: item, kind: c.queryItems?.first?.value.flatMap(BoxItem.Kind.init(rawValue:)))
    }
    public var url: URL {
        var c = URLComponents(); c.scheme = "box"; c.host = accountID.uuidString.lowercased()
        c.percentEncodedPath = "/" + boxEscape(itemID)
        if !itemID.isEmpty, let kind { c.percentEncodedQueryItems = [.init(name: "type", value: kind.rawValue)] }
        return c.url!
    }
    /// The API's ID: the root folder is "0".
    public var apiID: String { itemID.isEmpty ? BoxItem.rootID : itemID }
}

/// Percent-encodes everything but RFC 3986 unreserved characters: an ID or a name is always one opaque segment.
func boxEscape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: boxUnreserved)!
}
private let boxUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
