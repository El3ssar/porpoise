import Darwin
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
    static func load(
        _ url: URL, values v: URLResourceValues,
        finderMetadata: (URL) -> FinderMetadata? = FileItem.readFinderMetadata
    ) -> FileItem? {
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
        var customIcon = false
        if let metadata = finderMetadata(url) {
            customIcon = metadata.customIcon
            owner = Self.userName(metadata.uid)
            group = Self.groupName(metadata.gid)
            perms = Int(metadata.mode & 0o7777)
        } else {
            // Filesystems that cannot return Finder info still supply the existing POSIX metadata.
            var st = stat()
            if lstat(url.path, &st) == 0 {
                perms = Int(st.st_mode & 0o7777)
                owner = Self.userName(st.st_uid)
                group = Self.groupName(st.st_gid)
            }
            customIcon = customIconFlag(url)
        }
        return FileItem(
            url: url, name: name, isDirectory: isDir, isSymlink: isLink,
            isHidden: (v.isHidden ?? false) || name.hasPrefix("."),
            isPackage: isPackage, isApplication: isApp, size: size,
            modificationDate: v.contentModificationDate, creationDate: v.creationDate,
            accessDate: v.contentAccessDate, contentType: contentType,
            posixPermissions: perms, owner: owner, group: group, linkDestination: linkDest,
            isReadable: v.isReadable ?? true, isWritable: v.isWritable ?? true, hasCustomIcon: customIcon)
    }

    struct FinderMetadata {
        let uid: uid_t
        let gid: gid_t
        let mode: UInt32
        let customIcon: Bool
    }

    /// Fetch Finder info with ownership/mode in one syscall, replacing lstat. Attribute order is defined
    /// by attr.h; returned fields are packed on 4-byte boundaries. A nil result selects the POSIX fallback.
    static func readFinderMetadata(_ url: URL) -> FinderMetadata? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO | ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK)
        var metadata = [UInt32](repeating: 0, count: 12)
        guard getattrlist(url.path, &attributes, &metadata, metadata.count * 4, UInt32(FSOPT_NOFOLLOW)) == 0, metadata[0] >= 48 else { return nil }
        return FinderMetadata(
            uid: metadata[9], gid: metadata[10], mode: metadata[11],
            customIcon: metadata.withUnsafeBytes { $0[12] & 0x04 != 0 })
    }

    /// Finder flags are the big-endian UInt16 at bytes 8–9; kHasCustomIcon is 0x0400.
    /// This is part of loading the item's other metadata, off the drawing path.
    private static func customIconFlag(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW)
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
