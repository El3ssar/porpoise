import Foundation
import UniformTypeIdentifiers

/// One entry in a folder, with the attributes Dolphin's views need.
public struct FileItem: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let isPackage: Bool
    public let isApplication: Bool
    public let size: Int64
    public let modificationDate: Date?
    public let creationDate: Date?
    public let accessDate: Date?
    public let contentType: String?
    public let posixPermissions: Int
    public let owner: String?
    public let group: String?
    public let linkDestination: String?
    public let isReadable: Bool
    public let isWritable: Bool
    /// When it was shared with the user (cloud items in "Shared with me").
    public let sharedDate: Date?

    public init(
        url: URL, name: String, isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool = false,
        isPackage: Bool = false, isApplication: Bool = false, size: Int64 = 0,
        modificationDate: Date? = nil, creationDate: Date? = nil, accessDate: Date? = nil,
        contentType: String? = nil, posixPermissions: Int = 0o644, owner: String? = nil,
        group: String? = nil, linkDestination: String? = nil, isReadable: Bool = true,
        isWritable: Bool = true, sharedDate: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.isApplication = isApplication
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.accessDate = accessDate
        // Listings that carry no type (most cloud and remote ones): the type the name implies, as Finder would show.
        self.contentType = contentType ?? Self.contentType(forName: name, isDirectory: isDirectory)
        self.posixPermissions = posixPermissions
        self.owner = owner
        self.group = group
        self.linkDestination = linkDestination
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.sharedDate = sharedDate
    }

    /// The same item under another name (a cloud rename keeps the URL, an id). A new extension implies a new type.
    public func named(_ newName: String) -> FileItem {
        let sameExtension = (newName as NSString).pathExtension.lowercased() == (name as NSString).pathExtension.lowercased()
        return FileItem(
            url: url, name: newName, isDirectory: isDirectory, isSymlink: isSymlink, isHidden: newName.hasPrefix("."), isPackage: isPackage,
            isApplication: isApplication, size: size, modificationDate: modificationDate, creationDate: creationDate, accessDate: accessDate,
            contentType: isDirectory || sameExtension ? contentType : nil, posixPermissions: posixPermissions, owner: owner, group: group,
            linkDestination: linkDestination, isReadable: isReadable, isWritable: isWritable, sharedDate: sharedDate)
    }

    /// The type a name implies, for an item whose listing has none: a folder, else its extension's type (dynamic for
    /// an extension macOS doesn't know); nil for a file without an extension, which says nothing about its type.
    public static func contentType(forName name: String, isDirectory: Bool) -> String? {
        if isDirectory { return UTType.folder.identifier }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)?.identifier
    }

    /// The date a date role shows (nil for other roles).
    public func date(for role: ItemRole) -> Date? {
        switch role {
        case .modificationTime: return modificationDate
        case .creationTime: return creationDate
        case .accessTime: return accessDate
        case .sharedTime: return sharedDate
        default: return nil
        }
    }

    /// A Google Doc, Sheet, Slides…: a web document, opened in the browser, with no size of its own.
    public var isWebDocument: Bool { contentType?.hasPrefix("com.google.apps.") == true && !isDirectory }

    /// Folders the user browses into. Packages (.app, .bundle…) behave like files, as in Finder.
    public var isBrowsableFolder: Bool { isDirectory && !isPackage }
    /// A Finder alias (bookmark file).
    public var isAliasFile: Bool { contentType == "com.apple.alias-file" }

    public var fileExtension: String {
        isBrowsableFolder ? "" : (name as NSString).pathExtension
    }

    public var utType: UTType? { contentType.flatMap { UTType($0) } }

    public var mimeType: String? {
        if isBrowsableFolder { return "inode/directory" }
        return utType?.preferredMIMEType
    }

    /// Human readable type, e.g. "PDF document", "Folder".
    public var typeDescription: String {
        if isBrowsableFolder { return "Folder" }
        switch contentType {
        case "com.google.apps.document": return "Google Docs document"
        case "com.google.apps.spreadsheet": return "Google Sheets spreadsheet"
        case "com.google.apps.presentation": return "Google Slides presentation"
        case "com.google.apps.drawing": return "Google Drawing"
        case "com.google.apps.form": return "Google Form"
        default: break
        }
        if let c = contentType, let d = Self.typeDescriptions.description(of: c) { return d }
        return fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) file"
    }

    /// Descriptions by content type: a LaunchServices lookup each time made sorting by Type slow (two per
    /// comparison) and redid it for every row drawn in the Type column.
    private static let typeDescriptions = TypeDescriptions()
    private final class TypeDescriptions: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: String?] = [:]
        func description(of type: String) -> String? {
            if let d = lock.withLock({ known[type] }) { return d }
            let d = UTType(type)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            lock.withLock { known[type] = d }
            return d
        }
    }
}
