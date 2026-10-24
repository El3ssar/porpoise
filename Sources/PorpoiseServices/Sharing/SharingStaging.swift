import Darwin
import Foundation

/// A locked directory descriptor keeps another Porpoise process's launch sweep away from a live share.
final class SharingStagingLease: @unchecked Sendable {
    let folder: URL
    private let rootFD: Int32
    private let folderFD: Int32
    private let name: String

    init(folder: URL, rootFD: Int32, folderFD: Int32, name: String) {
        self.folder = folder; self.rootFD = rootFD; self.folderFD = folderFD; self.name = name
    }
    deinit {
        // Release the flock explicitly: any duplicate of this open-file description would
        // otherwise keep it held after close.
        _ = flock(folderFD, LOCK_UN)
        close(folderFD); close(rootFD)
    }

    func touch() { _ = futimes(folderFD, nil) }

    func remove() {
        guard SharingStaging.removeContents(folderFD) else { return }
        var current = stat(), held = stat()
        guard fstat(folderFD, &held) == 0, fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == held.st_dev, current.st_ino == held.st_ino
        else { return }
        _ = unlinkat(rootFD, name, AT_REMOVEDIR)
    }
}

enum SharingStaging {
    static let grace = SharingPreparation.successfulShareRetentionInterval
    static let rootName = "Porpoise-Sharing"
    private static let prefix = "Porpoise-Share-"
    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func create(in temporaryDirectory: URL) throws -> SharingStagingLease {
        let root = temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let rootFD = try openRoot(root)
        let name = prefix + UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { close(rootFD); throw POSIXError(.EIO) }
        let folderFD = openat(rootFD, name, flags)
        guard folderFD >= 0, flock(folderFD, LOCK_EX | LOCK_NB) == 0 else {
            if folderFD >= 0 { close(folderFD) }
            _ = unlinkat(rootFD, name, AT_REMOVEDIR); close(rootFD)
            throw POSIXError(.EIO)
        }
        return SharingStagingLease(folder: root.appendingPathComponent(name, isDirectory: true), rootFD: rootFD, folderFD: folderFD, name: name)
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        let fd = open(root.path, flags)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            close(fd); throw POSIXError(.EACCES)
        }
        return fd
    }

    /// Worker-only, descriptor-relative deletion. Never follows a root, candidate, or nested directory symlink.
    @discardableResult static func sweep(root: URL, now: Date = Date()) -> Int {
        guard let rootFD = try? openRoot(root) else { return 0 }
        defer { close(rootFD) }
        var removed = 0
        for name in names(rootFD) ?? [] {
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count)))?.uuidString == String(name.dropFirst(prefix.count))
            else { continue }
            let fd = openat(rootFD, name, flags)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, eligible(info, now: now), flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            // Recheck age after taking the lease: a just-completed share may have refreshed its grace period.
            guard fstat(fd, &info) == 0, eligible(info, now: now), removeContents(fd) else { continue }
            var current = stat()
            guard fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                unlinkat(rootFD, name, AT_REMOVEDIR) == 0
            else { continue }
            removed += 1
        }
        return removed
    }

    static func eligible(_ info: stat, now: Date) -> Bool {
        func seconds(_ stamp: timespec) -> TimeInterval { TimeInterval(stamp.tv_sec) + TimeInterval(stamp.tv_nsec) / 1_000_000_000 }
        let lastUse = max(seconds(info.st_mtimespec), seconds(info.st_birthtimespec))
        return info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR
            && now.timeIntervalSince1970 - lastUse > grace
    }

    private static func names(_ fd: Int32) -> [String]? {
        // A separately opened descriptor gives each enumeration its own directory offset.
        let copy = openat(fd, ".", flags)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? result : nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name != ".", name != ".." { result.append(name) }
        }
    }

    static func removeContents(_ fd: Int32, depth: Int = 0) -> Bool {
        guard depth < 128, let children = names(fd) else { return false }
        var success = true
        for name in children {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { success = false; continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, flags)
                guard child >= 0 else { success = false; continue }
                let removed = removeContents(child, depth: depth + 1)
                close(child)
                if !removed || unlinkat(fd, name, AT_REMOVEDIR) != 0 { success = false }
            } else if unlinkat(fd, name, 0) != 0 {
                success = false
            }
        }
        return success
    }
}
