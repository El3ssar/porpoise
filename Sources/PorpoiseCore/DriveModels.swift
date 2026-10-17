import Foundation
import UniformTypeIdentifiers

/// Account metadata only. OAuth credentials are stored separately in Keychain.
public struct DriveAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public var email: String
    public var displayName: String
    public var photoURL: URL?

    public init(id: UUID = UUID(), subject: String, email: String, displayName: String, photoURL: URL? = nil) {
        self.id = id
        self.subject = subject
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
    }
}

/// Names never participate in identity: renaming a folder does not invalidate a Place.
public struct DriveLocation: Hashable, Sendable {
    public enum Collection: Hashable, Sendable {
        case myDrive, sharedWithMe, sharedDrives
        case folder(String, driveID: String? = nil)
    }

    public let accountID: UUID
    public let collection: Collection
    public let resourceKey: String?
    public let navigationPath: [String]?

    public init(accountID: UUID, collection: Collection = .myDrive, resourceKey: String? = nil, navigationPath: [String]? = nil) {
        self.accountID = accountID
        self.collection = collection
        self.resourceKey = resourceKey
        self.navigationPath = navigationPath
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "gdrive"
        c.host = accountID.uuidString.lowercased()
        var query: [URLQueryItem] = []
        switch collection {
        case .myDrive: c.path = "/my-drive"
        case .sharedWithMe: c.path = "/shared-with-me"
        case .sharedDrives: c.path = "/shared-drives"
        case .folder(let id, let driveID):
            c.path = "/folder/\(id)"
            if let driveID { query.append(URLQueryItem(name: "driveID", value: driveID)) }
        }
        if let navigationPath { c.path = "/" + navigationPath.joined(separator: "/") }
        if let resourceKey { query.append(URLQueryItem(name: "resourceKey", value: resourceKey)) }
        c.path += "/"
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "gdrive", let host = url.host, let accountID = UUID(uuidString: host),
            url.user == nil, url.password == nil, url.port == nil,
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let collection: Collection
        switch parts {
        case ["my-drive"]: collection = .myDrive
        case ["shared-with-me"]: collection = .sharedWithMe
        case ["shared-drives"]: collection = .sharedDrives
        default:
            guard parts.count >= 2, ["folder", "my-drive", "shared-with-me", "shared-drives"].contains(parts[0]),
                parts.dropFirst().allSatisfy(DriveLink.isValidID), parts[0] != "folder" || parts.count >= 2
            else { return nil }
            let driveID = c.queryItems?.first { $0.name == "driveID" }?.value ?? (parts[0] == "shared-drives" ? parts[1] : nil)
            collection = .folder(parts.last!, driveID: driveID)
        }
        self.init(
            accountID: accountID, collection: collection, resourceKey: c.queryItems?.first { $0.name == "resourceKey" }?.value, navigationPath: parts)
    }

    public var title: String {
        switch collection {
        case .myDrive: return "My Drive"
        case .sharedWithMe: return "Shared with me"
        case .sharedDrives: return "Shared drives"
        case .folder: return "Google Drive folder"
        }
    }
}

public struct DriveLink: Equatable, Sendable {
    public let itemID: String
    public let resourceKey: String?
    public let isFolder: Bool

    public init?(url: URL) {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
            let host = url.host?.lowercased(), ["drive.google.com", "docs.google.com"].contains(host)
        else { return nil }
        let p = url.pathComponents.filter { $0 != "/" }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var id: String?
        var folder = false
        if host == "drive.google.com", p.first == "drive", let index = p.firstIndex(of: "folders"), index + 1 == p.count - 1 {
            id = p[index + 1]; folder = true
        } else if let index = p.firstIndex(of: "d"), index + 1 < p.count {
            id = p[index + 1]
        } else if host == "drive.google.com", p == ["open"] || p == ["uc"] {
            id = q.first { $0.name == "id" }?.value
        }
        guard let id, Self.isValidID(id) else { return nil }
        itemID = id
        resourceKey = q.first { $0.name == "resourcekey" }?.value
        isFolder = folder
    }

    public func location(accountID: UUID) -> DriveLocation {
        DriveLocation(accountID: accountID, collection: .folder(itemID), resourceKey: resourceKey)
    }

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

public enum DriveExportPreset: String, Codable, CaseIterable, Sendable {
    case office, pdf, openDocument

    public func format(for mimeType: String) -> (mimeType: String, fileExtension: String)? {
        let kind = mimeType.replacingOccurrences(of: "application/vnd.google-apps.", with: "")
        switch (self, kind) {
        case (.office, "document"): return ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        case (.office, "spreadsheet"): return ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        case (.office, "presentation"): return ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        case (.openDocument, "document"): return ("application/vnd.oasis.opendocument.text", "odt")
        case (.openDocument, "spreadsheet"): return ("application/vnd.oasis.opendocument.spreadsheet", "ods")
        case (.openDocument, "presentation"): return ("application/vnd.oasis.opendocument.presentation", "odp")
        case (.pdf, "document"), (.pdf, "spreadsheet"), (.pdf, "presentation"), (.pdf, "drawing"): return ("application/pdf", "pdf")
        case (_, "drawing"): return ("application/pdf", "pdf")
        default: return nil
        }
    }
}

/// Explicit per-item operation availability. Missing mutation grants are denied.
public struct DriveCapabilities: Equatable, Sendable {
    public let canBrowse: Bool
    public let canDownload: Bool
    public let canExport: Bool
    public let canOpenInBrowser: Bool
    public var canWrite: Bool = false
    public var canRename: Bool = false
    public var canTrash: Bool = false
    public var canUntrash: Bool = false
    public var canAddChildren: Bool = false
    public var canMove: Bool = false
    public var canCopy: Bool = false
    public var canEdit: Bool { canWrite }
    public var canMoveItemWithinDrive: Bool { canMove }
    public var role: String? = nil
}

public typealias DriveItemCapabilities = DriveCapabilities

public struct DrivePerson: Codable, Hashable, Sendable {
    public var displayName: String?
    public var emailAddress: String?
    public var photoLink: URL?
}

/// Drive metadata remains available for Properties without inventing POSIX attributes.
public struct DriveFile: Codable, Hashable, Sendable {
    public struct Access: Codable, Hashable, Sendable {
        public var canDownload: Bool?
        public var canListChildren: Bool?
        public var canEdit: Bool?
        public var canRename: Bool?
        public var canTrash: Bool?
        public var canUntrash: Bool?
        public var canAddChildren: Bool?
        public var canMoveItemWithinDrive: Bool?
        public var canMoveItemOutOfDrive: Bool?
        public var canCopy: Bool?
    }
    public struct Shortcut: Codable, Hashable, Sendable {
        public var targetId: String
        public var targetMimeType: String?
        public var targetResourceKey: String?
    }
    public var id: String
    public var name: String
    public var mimeType: String
    public var driveId: String?
    public var resourceKey: String?
    public var size: String?
    public var parents: [String]?
    public var headRevisionId: String?
    public var version: String?
    public var md5Checksum: String?
    public var appProperties: [String: String]?
    public var modifiedTime: String?
    public var thumbnailLink: URL?
    public var hasThumbnail: Bool?
    public var webViewLink: URL?
    public var owners: [DrivePerson]?
    public var shared: Bool?
    public var capabilities: Access?
    public var shortcutDetails: Shortcut?
    public var exportLinks: [String: URL]?
    public var trashed: Bool?
    public struct Permission: Codable, Hashable, Sendable {
        public var id: String?
        public var type: String?
        public var role: String?
        public var displayName: String?
        public var emailAddress: String?
        public var photoLink: URL?
    }
    public var permissions: [Permission]?
    public var sharingUser: DrivePerson?
    public var lastModifyingUser: DrivePerson?
    /// When it was shared with the user (Shared with me's newest-first order and its "Shared" column).
    public var sharedWithMeTime: String?

    public init(id: String, name: String, mimeType: String, driveId: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.driveId = driveId
    }

    public var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    public var isShortcut: Bool { mimeType == "application/vnd.google-apps.shortcut" }
    public var isGoogleDocument: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder && !isShortcut }
    public var operations: DriveCapabilities {
        DriveCapabilities(
            canBrowse: isFolder && capabilities?.canListChildren != false,
            canDownload: !isFolder && !isGoogleDocument && !isShortcut && capabilities?.canDownload != false,
            canExport: isGoogleDocument && capabilities?.canDownload != false,
            canOpenInBrowser: webViewLink != nil,
            canWrite: capabilities?.canEdit == true,
            canRename: capabilities?.canRename == true,
            canTrash: capabilities?.canTrash == true,
            canUntrash: capabilities?.canUntrash == true,
            canAddChildren: isFolder && capabilities?.canAddChildren == true,
            canMove: capabilities?.canMoveItemWithinDrive == true,
            canCopy: capabilities?.canCopy == true)
    }

    /// Native Google identities stay distinct from their downloadable export formats.
    public var contentType: String {
        if isFolder { return "public.folder" }
        if isGoogleDocument { return "com.google.apps." + mimeType.dropFirst("application/vnd.google-apps.".count) }
        return UTType(mimeType: mimeType)?.identifier ?? "public.data"
    }

    public func location(accountID: UUID) -> DriveLocation {
        DriveLocation(accountID: accountID, collection: .folder(id, driveID: driveId), resourceKey: resourceKey)
    }

    public func childLocation(in parent: DriveLocation) -> DriveLocation {
        let parts = parent.url.pathComponents.filter { $0 != "/" } + [id]
        return DriveLocation(accountID: parent.accountID, collection: .folder(id, driveID: driveId), resourceKey: resourceKey, navigationPath: parts)
    }

    public func fileItem(accountID: UUID, shortcutTarget: DriveFile? = nil, parent: DriveLocation? = nil) -> FileItem {
        let target = shortcutTarget ?? self
        return FileItem(
            url: parent.map { childLocation(in: $0).url } ?? location(accountID: accountID).url, name: name, isDirectory: target.isFolder,
            isSymlink: isShortcut, isHidden: name.hasPrefix("."), size: Int64(target.size ?? "") ?? 0,
            modificationDate: target.modifiedTime.flatMap { ISO8601DateFormatter().date(from: $0) },
            contentType: target.contentType, posixPermissions: target.isFolder ? 0o555 : 0o444,
            owner: owners?.first?.displayName ?? owners?.first?.emailAddress,
            linkDestination: shortcutDetails?.targetId,
            isReadable: target.isFolder ? target.operations.canBrowse : (target.operations.canDownload || target.operations.canExport),
            isWritable: target.operations.canWrite || target.operations.canAddChildren,
            sharedDate: sharedWithMeTime.flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}
