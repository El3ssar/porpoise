import Foundation
import PorpoiseCore

public enum OneDriveError: Error, Equatable, LocalizedError {
    case invalidResponse, invalidLocation, reconnect, offline, conflict, notFound, sourceChanged, uncertain, unsupportedUndo, http(Int), api(
        Int, String), offset(Int64)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "OneDrive returned an invalid response."
        case .invalidLocation: return "This OneDrive location is invalid."
        case .reconnect: return "Sign in to OneDrive again."
        case .offline: return "OneDrive is offline."
        case .conflict: return "The destination exists or the file changed."
        case .notFound: return "This OneDrive item no longer exists."
        case .sourceChanged: return "The source changed during the transfer."
        case .uncertain: return "OneDrive may have applied this change. Review it before trying again."
        case .unsupportedUndo: return "OneDrive cannot safely undo this change."
        case .http(let status), .api(let status, _): return "OneDrive request failed (\(status))."
        case .offset: return "OneDrive upload offset changed."
        }
    }
}

/// A Graph driveItem. IDs (item and drive) are opaque and never reconstructed from names or paths. Download URLs are
/// short-lived bearer capabilities: they are never decoded into this (cached, persisted) value.
/// https://learn.microsoft.com/graph/api/resources/driveitem
public struct OneDriveItem: CloudMetadataItem, Equatable {
    public var id: String
    public var name: String
    public var driveID: String?
    public var parentID: String?
    public var eTag: String?
    public var cTag: String?
    public var size: Int64?
    public var quickXorHash: String?
    public var mimeType: String?
    public var modified: String?
    public var isFolder: Bool
    public var isRoot = false
    public var isDeleted = false
    /// A OneNote notebook or similar package: browsable on the web, not a downloadable file.
    public var isPackage = false
    public init(
        id: String, name: String, folder: Bool = false, driveID: String? = nil, parentID: String? = nil, eTag: String? = nil,
        cTag: String? = nil, size: Int64? = nil, quickXorHash: String? = nil
    ) {
        self.id = id; self.name = name; isFolder = folder; self.driveID = driveID; self.parentID = parentID
        self.eTag = eTag; self.cTag = cTag; self.size = size; self.quickXorHash = quickXorHash
    }
    /// The content revision: the cTag changes with the bytes only (a rename keeps it); the eTag where there's none.
    public var revision: String? { cTag ?? eTag }
    public var canDownload: Bool { !isFolder && !isPackage && !isDeleted }

    private enum Keys: String, CodingKey {
        case id, name, eTag, cTag, size, file, folder, root, deleted, package, remoteItem, parentReference, lastModifiedDateTime
    }
    private enum ParentKeys: String, CodingKey { case driveId, id }
    private enum FileKeys: String, CodingKey { case mimeType, hashes }
    private enum HashKeys: String, CodingKey { case quickXorHash }
    private struct Empty: Codable {}
    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Keys.self)
        // A shared item (sharedWithMe, a shortcut in My files) names its target in remoteItem: that is what opens.
        let c = outer.contains(.remoteItem) ? try outer.nestedContainer(keyedBy: Keys.self, forKey: .remoteItem) : outer
        id = try c.decode(String.self, forKey: .id)
        name = try outer.decodeIfPresent(String.self, forKey: .name) ?? c.decodeIfPresent(String.self, forKey: .name) ?? ""
        guard !id.isEmpty else { throw OneDriveError.invalidResponse }
        eTag = try c.decodeIfPresent(String.self, forKey: .eTag); cTag = try c.decodeIfPresent(String.self, forKey: .cTag)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        modified = try c.decodeIfPresent(String.self, forKey: .lastModifiedDateTime)
        isFolder = c.contains(.folder)
        isRoot = outer.contains(.root); isDeleted = outer.contains(.deleted); isPackage = c.contains(.package)
        if let file = try? c.nestedContainer(keyedBy: FileKeys.self, forKey: .file) {
            mimeType = try file.decodeIfPresent(String.self, forKey: .mimeType)
            if let hashes = try? file.nestedContainer(keyedBy: HashKeys.self, forKey: .hashes) {
                quickXorHash = try hashes.decodeIfPresent(String.self, forKey: .quickXorHash)
            }
        }
        if let parent = try? c.nestedContainer(keyedBy: ParentKeys.self, forKey: .parentReference) {
            driveID = try parent.decodeIfPresent(String.self, forKey: .driveId)
        }
        // Membership is where the entry appears (a shortcut lives in this folder), identity is the target's.
        if let parent = try? outer.nestedContainer(keyedBy: ParentKeys.self, forKey: .parentReference) {
            parentID = try parent.decodeIfPresent(String.self, forKey: .id)
            if driveID == nil { driveID = try parent.decodeIfPresent(String.self, forKey: .driveId) }
        }
        // A deleted entry carries neither a file nor a folder facet; it is only ever removed.
        guard isDeleted || isRoot || isFolder || isPackage || c.contains(.file) else { throw OneDriveError.invalidResponse }
    }
    /// Written in Graph's own shape, so a cached item reads back exactly as it was received.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encodeIfPresent(eTag, forKey: .eTag); try c.encodeIfPresent(cTag, forKey: .cTag)
        try c.encodeIfPresent(size, forKey: .size); try c.encodeIfPresent(modified, forKey: .lastModifiedDateTime)
        if isFolder { try c.encode(Empty(), forKey: .folder) }
        if isRoot { try c.encode(Empty(), forKey: .root) }
        if isDeleted { try c.encode(Empty(), forKey: .deleted) }
        if isPackage { try c.encode(Empty(), forKey: .package) }
        if !isFolder, !isPackage, !isRoot, !isDeleted {
            var file = c.nestedContainer(keyedBy: FileKeys.self, forKey: .file)
            try file.encodeIfPresent(mimeType, forKey: .mimeType)
            var hashes = file.nestedContainer(keyedBy: HashKeys.self, forKey: .hashes)
            try hashes.encodeIfPresent(quickXorHash, forKey: .quickXorHash)
        }
        var parent = c.nestedContainer(keyedBy: ParentKeys.self, forKey: .parentReference)
        try parent.encodeIfPresent(driveID, forKey: .driveId); try parent.encodeIfPresent(parentID, forKey: .id)
    }
    public func fileItem(accountID: UUID, driveID: String? = nil) -> FileItem {
        FileItem(
            url: OneDriveLocation(accountID: accountID, itemID: isRoot ? "" : id, driveID: self.driveID ?? driveID).url, name: name,
            isDirectory: isFolder || isRoot, size: size ?? 0)
    }
}

public struct OneDriveAccount: Codable, Equatable, Sendable {
    public var id: UUID
    /// Graph's user ID: the same person signing in again has the same one.
    public var userID: String
    public var email: String
    public var displayName: String
    public var driveID: String
    /// personal, business or documentLibrary.
    public var driveType: String
}

/// One encoded segment holds the entire opaque item ID; the drive ID is a query value. Neither is split or parsed.
public struct OneDriveLocation: Equatable, Sendable {
    public let accountID: UUID
    public let itemID: String
    public let driveID: String?
    public init(accountID: UUID, itemID: String = "", driveID: String? = nil) {
        self.accountID = accountID; self.itemID = itemID; self.driveID = driveID
    }
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "onedrive", let host = c.host,
            let account = UUID(uuidString: host), c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
            (c.queryItems ?? []).allSatisfy({ $0.name == "drive" && $0.value?.isEmpty == false }), (c.queryItems ?? []).count <= 1,
            c.percentEncodedPath.hasPrefix("/"), let item = String(c.percentEncodedPath.dropFirst()).removingPercentEncoding,
            !String(c.percentEncodedPath.dropFirst()).contains("/")
        else { return nil }
        self.init(accountID: account, itemID: item, driveID: c.queryItems?.first?.value)
    }
    public var url: URL {
        var c = URLComponents(); c.scheme = "onedrive"; c.host = accountID.uuidString.lowercased()
        c.percentEncodedPath = "/" + oneDriveEscape(itemID)
        if let driveID { c.percentEncodedQueryItems = [.init(name: "drive", value: oneDriveEscape(driveID))] }
        return c.url!
    }
}

/// Percent-encodes everything but RFC 3986 unreserved characters: an ID or a name is always one opaque segment.
func oneDriveEscape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: oneDriveUnreserved)!
}
private let oneDriveUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
