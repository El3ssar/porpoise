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

    public init(
        url: URL, name: String, isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool = false,
        isPackage: Bool = false, isApplication: Bool = false, size: Int64 = 0,
        modificationDate: Date? = nil, creationDate: Date? = nil, accessDate: Date? = nil,
        contentType: String? = nil, posixPermissions: Int = 0o644, owner: String? = nil,
        group: String? = nil, linkDestination: String? = nil, isReadable: Bool = true,
        isWritable: Bool = true
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
        self.contentType = contentType
        self.posixPermissions = posixPermissions
        self.owner = owner
        self.group = group
        self.linkDestination = linkDestination
        self.isReadable = isReadable
        self.isWritable = isWritable
    }

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
        if let t = utType, let d = t.localizedDescription { return d.prefix(1).uppercased() + d.dropFirst() }
        return fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) file"
    }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey, .isApplicationKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentAccessDateKey, .contentTypeKey, .isReadableKey, .isWritableKey,
    ]

    /// Reads an item from disk. Symlinks report their target's type (like Dolphin), but keep `isSymlink`.
    public static func load(_ url: URL) -> FileItem? {
        let keys = Set(resourceKeys)
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        // The file system's spelling (case, a volume's name for "/"), except that Foundation drops a leading U+FEFF
        // from names it reads: then the URL's own name is the real one.
        let last = url.lastPathComponent
        let name = last.unicodeScalars.first == "\u{FEFF}" ? last : (v.name ?? last)
        var isDir = v.isDirectory ?? false
        let isLink = v.isSymbolicLink ?? false
        var linkDest: String?
        var contentType = v.contentType?.identifier
        var size = Int64(v.fileSize ?? 0)
        var isPackage = v.isPackage ?? false
        var isApp = v.isApplication ?? false
        if isLink {
            linkDest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let resolved = url.resolvingSymlinksInPath()
            if let rv = try? resolved.resourceValues(forKeys: keys) {
                isDir = rv.isDirectory ?? false
                contentType = rv.contentType?.identifier ?? contentType
                size = Int64(rv.fileSize ?? 0)
                isPackage = rv.isPackage ?? false
                isApp = rv.isApplication ?? false
            }
        }
        var perms = 0o644
        var owner: String?
        var group: String?
        var st = stat()
        if lstat(url.path, &st) == 0 {
            perms = Int(st.st_mode & 0o7777)
            owner = Self.userName(st.st_uid)
            group = Self.groupName(st.st_gid)
        }
        return FileItem(
            url: url, name: name, isDirectory: isDir, isSymlink: isLink,
            isHidden: (v.isHidden ?? false) || name.hasPrefix("."),
            isPackage: isPackage, isApplication: isApp, size: size,
            modificationDate: v.contentModificationDate, creationDate: v.creationDate,
            accessDate: v.contentAccessDate, contentType: contentType,
            posixPermissions: perms, owner: owner, group: group, linkDestination: linkDest,
            isReadable: v.isReadable ?? true, isWritable: v.isWritable ?? true)
    }

    nonisolated(unsafe) private static var userCache: [uid_t: String] = [:]
    nonisolated(unsafe) private static var groupCache: [gid_t: String] = [:]
    private static let cacheLock = NSLock()

    static func userName(_ uid: uid_t) -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let n = userCache[uid] { return n }
        let n = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userCache[uid] = n
        return n
    }

    static func groupName(_ gid: gid_t) -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let n = groupCache[gid] { return n }
        let n = getgrgid(gid).flatMap { String(cString: $0.pointee.gr_name) } ?? String(gid)
        groupCache[gid] = n
        return n
    }
}

public enum DirectoryLister {
    /// Lists a folder (all entries, including hidden ones; the model decides what to show).
    public static func list(_ folder: URL) throws -> [FileItem] {
        // Names from URLs: the String-based listing drops a leading U+FEFF, which would lose the file. The URL-based
        // one doesn't follow a symlink to a folder, so it is given the real folder; items keep `folder` as named.
        let names = try FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        var items: [FileItem] = []
        items.reserveCapacity(names.count)
        for n in names {
            if let item = FileItem.load(folder.appendingPathComponent(n)) { items.append(item) }
        }
        return items
    }

    /// Number of entries in a folder (Dolphin's default "Size" for folders), skipping hidden ones
    /// unless asked.
    public static func childCount(_ folder: URL, includeHidden: Bool) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return includeHidden ? names.count : names.filter { !$0.hasPrefix(".") }.count
    }
}
