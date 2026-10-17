import Foundation
import PorpoiseCore

public enum DropboxError: Error, Equatable, LocalizedError {
    case invalidResponse, invalidLocation, reconnect, offline, conflict, notFound, sourceChanged, uncertain, unsupportedUndo, http(Int), api(
        Int, String), offset(Int64)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Dropbox returned an invalid response."
        case .invalidLocation: return "This Dropbox location is invalid."
        case .reconnect: return "Sign in to Dropbox again."
        case .offline: return "Dropbox is offline."
        case .conflict: return "The destination exists or the file changed."
        case .notFound: return "This Dropbox item no longer exists."
        case .sourceChanged: return "The source changed during the transfer."
        case .uncertain: return "Dropbox may have applied this change. Review it before trying again."
        case .unsupportedUndo: return "Dropbox cannot safely undo this change."
        case .http(let status), .api(let status, _): return "Dropbox request failed (\(status))."
        case .offset: return "Dropbox upload offset changed."
        }
    }
}

/// Opaque IDs and revisions are never reconstructed from display paths.
public struct DropboxItem: CloudMetadataItem, Equatable {
    public var tag: String
    public var id: String
    public var name: String
    public var pathLower: String?
    public var pathDisplay: String?
    public var rev: String?
    public var size: Int64?
    public var contentHash: String?
    public var serverModified: String?
    public var isDownloadable: Bool?
    enum CodingKeys: String, CodingKey {
        case tag = ".tag", id, name, rev, size
        case pathLower = "path_lower", pathDisplay = "path_display", contentHash = "content_hash"
        case serverModified = "server_modified", isDownloadable = "is_downloadable"
    }
    public init(
        id: String, name: String, tag: String = "file", path: String? = nil, rev: String? = nil, size: Int64? = nil, contentHash: String? = nil
    ) {
        self.id = id; self.name = name; self.tag = tag; self.pathLower = path?.lowercased(); self.pathDisplay = path
        self.rev = rev; self.size = size; self.contentHash = contentHash
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = try c.decodeIfPresent(String.self, forKey: .rev); size = try c.decodeIfPresent(Int64.self, forKey: .size)
        // Only a Metadata union names its subtype. A route typed FileMetadata (download's Dropbox-API-Result, upload,
        // restore) or FolderMetadata (create_folder_v2) sends none; a file always has a rev, a folder never does.
        // https://github.com/dropbox/dropbox-api-spec/blob/master/files.stone
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? (rev == nil ? "folder" : "file")
        name = try c.decode(String.self, forKey: .name)
        pathLower = try c.decodeIfPresent(String.self, forKey: .pathLower); pathDisplay = try c.decodeIfPresent(String.self, forKey: .pathDisplay)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? (tag == "deleted" ? pathLower ?? "" : "")
        guard !id.isEmpty, ["file", "folder", "deleted"].contains(tag) else { throw DropboxError.invalidResponse }
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        serverModified = try c.decodeIfPresent(String.self, forKey: .serverModified)
        isDownloadable = try c.decodeIfPresent(Bool.self, forKey: .isDownloadable)
    }
    public var isFolder: Bool { tag == "folder" }
    public var parentPath: String { (pathLower ?? "").split(separator: "/").dropLast().map { "/" + $0 }.joined() }
    public func fileItem(accountID: UUID, namespaceID: String? = nil) -> FileItem {
        FileItem(
            url: DropboxLocation(accountID: accountID, itemID: id, namespaceID: namespaceID).url, name: name, isDirectory: isFolder, size: size ?? 0)
    }
}

public struct DropboxPage: Decodable, Sendable {
    public var entries: [DropboxItem]
    public var cursor: String
    public var hasMore: Bool
    enum CodingKeys: String, CodingKey { case entries, cursor; case hasMore = "has_more" }
}
public struct DropboxAccount: Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: String
    public var email: String
    public var displayName: String
    public var rootNamespaceID: String
    public var homeNamespaceID: String
    public var hasTeamSpace: Bool { rootNamespaceID != homeNamespaceID }
}

/// One encoded segment contains the entire opaque ID, including any embedded slash.
public struct DropboxLocation: Equatable, Sendable {
    public let accountID: UUID
    public let itemID: String
    public let namespaceID: String?
    public init(accountID: UUID, itemID: String = "", namespaceID: String? = nil) {
        self.accountID = accountID; self.itemID = itemID; self.namespaceID = namespaceID
    }
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "dropbox", let host = c.host,
            let account = UUID(uuidString: host), c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
            (c.queryItems ?? []).allSatisfy({ $0.name == "namespace" && $0.value?.isEmpty == false }), (c.queryItems ?? []).count <= 1,
            c.percentEncodedPath.hasPrefix("/"), let item = String(c.percentEncodedPath.dropFirst()).removingPercentEncoding,
            !String(c.percentEncodedPath.dropFirst()).contains("/")
        else { return nil }
        self.init(accountID: account, itemID: item, namespaceID: c.queryItems?.first?.value)
    }
    public var url: URL {
        var c = URLComponents(); c.scheme = "dropbox"; c.host = accountID.uuidString.lowercased()
        c.percentEncodedPath = "/" + itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        if let namespaceID { c.queryItems = [.init(name: "namespace", value: namespaceID)] }
        return c.url!
    }
}

/// Header arguments must be ASCII JSON, even for non-ASCII filenames and supplementary Unicode scalars.
func dropboxHeader(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    guard let string = String(data: data, encoding: .utf8) else { throw DropboxError.invalidResponse }
    return string.utf16.map { unit in unit >= 127 ? String(format: "\\u%04x", unit) : String(UnicodeScalar(unit)!) }.joined()
}
