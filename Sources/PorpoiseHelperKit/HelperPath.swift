import Darwin
import Foundation

final class HelperDescriptor {
    let fd: Int32
    init(_ fd: Int32) throws {
        guard fd >= 0 else { throw HelperFailure.system("Could not open the item") }
        self.fd = fd
    }
    deinit { close(fd) }
    var info: stat {
        get throws {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw HelperFailure.system("Could not inspect the opened item") }
            return value
        }
    }
    var path: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return fcntl(fd, F_GETPATH, &buffer) == 0 ? String(cString: buffer) : nil
    }
}

struct HelperIdentity: Equatable, Hashable, Codable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let type: mode_t
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; generation = info.st_gen; type = info.st_mode & S_IFMT
    }
}

/// A pinned parent plus a single basename. The original pathname is never passed to a mutating syscall.
final class HelperPath {
    enum Access { case read, write, remove }
    let parent: HelperDescriptor
    let name: String
    let display: String
    let expected: stat?
    let leaf: HelperDescriptor?
    private let canonicalParent: String?
    private let parentIdentity: HelperIdentity

    init(_ path: String, access: Access, missing: Bool = false, boundary: (HelperBoundary) -> Void) throws {
        guard HelperRequests.isPath(path) else { throw HelperFailure.changed }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw HelperFailure.changed }
        guard let canonical = ExistingPath.resolve((path as NSString).deletingLastPathComponent) else {
            throw HelperFailure.system("Could not open the containing folder")
        }
        let full = canonical + "/" + name
        let allowed: Bool
        switch access {
        case .read: allowed = HelperRequests.isPath(full)
        case .write: allowed = HelperRequests.writable(full)
        case .remove: allowed = HelperRequests.removable(full)
        }
        guard allowed else { throw HelperFailure("That location is not allowed for this operation.") }
        var parentInfo = stat()
        guard lstat(canonical, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else { throw HelperFailure.changed }
        let identity = HelperIdentity(parentInfo)
        let expected = try Self.statAt(AT_FDCWD, full, missing: missing)
        boundary(HelperBoundary(phase: .beforeParentOpen, path: path))
        let parent = try HelperDescriptor(open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC))
        guard try HelperIdentity(parent.info) == identity else { throw HelperFailure.changed }
        self.parent = parent; self.name = name; display = path
        canonicalParent = canonical; parentIdentity = identity; self.expected = expected
        boundary(HelperBoundary(phase: .afterParentOpen, path: path))
        leaf = try Self.openLeaf(parent.fd, name, expected: expected)
        boundary(HelperBoundary(phase: .afterLeafOpen, path: path))
        try validate()
    }

    /// Children stay beneath an already validated descriptor; symlinks are opened as objects, never traversed.
    init(parent: HelperDescriptor, name: String, display: String) throws {
        self.parent = parent; self.name = name; self.display = display
        canonicalParent = nil; parentIdentity = try HelperIdentity(parent.info)
        expected = try Self.statAt(parent.fd, name, missing: false)
        leaf = try Self.openLeaf(parent.fd, name, expected: expected)
        try validate()
    }

    func validateParent() throws {
        if let canonicalParent {
            let current = try HelperDescriptor(open(canonicalParent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC))
            guard try HelperIdentity(current.info) == parentIdentity else { throw HelperFailure.changed }
        }
    }

    func validate() throws {
        try validateParent()
        let current = try Self.statAt(parent.fd, name, missing: true)
        guard current.map(HelperIdentity.init) == expected.map(HelperIdentity.init) else { throw HelperFailure.changed }
        if let leaf, let expected {
            guard try HelperIdentity(leaf.info) == HelperIdentity(expected) else { throw HelperFailure.changed }
        }
    }

    static func statAt(_ dir: Int32, _ name: String, missing: Bool) throws -> stat? {
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if missing && errno == ENOENT { return nil }
        throw HelperFailure.system("Could not inspect “\(name)”")
    }

    private static func openLeaf(_ dir: Int32, _ name: String, expected: stat?) throws -> HelperDescriptor? {
        guard let expected else { return nil }
        let type = expected.st_mode & S_IFMT
        guard [S_IFREG, S_IFDIR, S_IFLNK].contains(type) else { throw HelperFailure("This kind of filesystem item is not supported by the helper.") }
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (type == S_IFLNK ? O_SYMLINK : O_NOFOLLOW)
        let descriptor = try HelperDescriptor(openat(dir, name, flags))
        guard try HelperIdentity(descriptor.info) == HelperIdentity(expected) else { throw HelperFailure.changed }
        return descriptor
    }

    static func names(_ directory: HelperDescriptor) throws -> [String] {
        let copy = dup(directory.fd)
        guard copy >= 0 else { throw HelperFailure.system("Could not enumerate the folder") }
        guard let entries = fdopendir(copy) else { close(copy); throw HelperFailure.system("Could not enumerate the folder") }
        defer { closedir(entries) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(entries) else {
                guard errno == 0 else { throw HelperFailure.system("Could not enumerate the folder") }
                return names.sorted()
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(validatingCString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard let name else { throw HelperFailure("A filename cannot be represented safely by this request.") }
            if name != ".", name != ".." { names.append(name) }
            guard names.count <= 1_000_000 else { throw HelperFailure("The folder has too many entries for this request.") }
        }
    }
}
