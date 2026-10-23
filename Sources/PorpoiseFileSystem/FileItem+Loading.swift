import Foundation
import PorpoiseCore
import UniformTypeIdentifiers

extension FileItem {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey, .isApplicationKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentAccessDateKey, .contentTypeKey, .isReadableKey, .isWritableKey,
    ]
    /// Built once: hashing the keys for every item showed up in listings.
    static let resourceKeySet = Set(resourceKeys)

    /// Reads an item from disk. Symlinks report their target's type (like Dolphin), but keep `isSymlink`.
    public static func load(_ url: URL) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: resourceKeySet) else { return nil }
        return load(url, values: v)
    }

    /// `load`, from values already read (a listing fetches them for all its entries at once).
    static func load(_ url: URL, values v: URLResourceValues) -> FileItem? {
        let keys = resourceKeySet
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
            isReadable: v.isReadable ?? true, isWritable: v.isWritable ?? true, hasCustomIcon: customIconFlag(url))
    }

    /// Finder flags are the big-endian UInt16 at bytes 8–9; kHasCustomIcon is 0x0400.
    /// This is part of loading the item's other metadata, off the drawing path.
    private static func customIconFlag(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, 0)
        return count >= 10 && info[8] & 0x04 != 0
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
