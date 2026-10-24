import Darwin
import Foundation

/// Privileged operations use descriptor capabilities, never re-launch a tool with the original paths.
struct HelperFileOperations {
    let boundary: (HelperBoundary) -> Void
    /// Each step is classified again from what it opened, right before it changes anything: a folder swapped for a
    /// link after the person approved can't take it somewhere that needs more approval than they gave. Nil: no
    /// check (tests of the descriptor mechanics).
    var policy: HelperPolicy?
    var authorized: HelperTier = .standard
    private let move: (Int32, String, Int32, String, UInt32) -> Int32
    private var stages: [HelperStage] = []
    private var visited: Set<HelperIdentity> = []
    private var entries = 0

    init(
        boundary: @escaping (HelperBoundary) -> Void = { _ in }, policy: HelperPolicy? = nil, authorized: HelperTier = .standard,
        move: @escaping (Int32, String, Int32, String, UInt32) -> Int32 = { renameatx_np($0, $1, $2, $3, $4) }
    ) { self.boundary = boundary; self.policy = policy; self.authorized = authorized; self.move = move }

    static let changedTier = HelperFailure("The item changed during the request; try again.")

    /// Refuses `op` when what it opened needs more approval than was given.
    private func permit(_ op: HelperOperation, _ opened: [HelperPath]) throws {
        guard let policy else { return }
        let tier = policy.tier(of: op) { p in opened.first { $0.display == p }?.facts ?? HelperPathFacts.read(p) }.tier
        guard tier <= authorized, tier != .never else { throw Self.changedTier }
    }

    mutating func run(_ arguments: [String]) -> String? {
        stages.removeAll(); visited.removeAll(); entries = 0
        do {
            try execute(HelperOperation(arguments))
            return nil
        } catch {
            // Children restore before their captured parent. Exclusive renames never discard a new generation.
            for stage in stages.reversed() {
                if stage.original != nil {
                    stage.restore()
                } else {
                    do { try removeOwned(stage.directory, stage.entry); stage.present = false; stage.finishEmpty() } catch {}
                }
            }
            let retained = stages.filter { $0.present }.map { $0.recoveryPath }
            let recovery = retained.isEmpty ? "" : " Items were kept for recovery at: " + retained.joined(separator: ", ") + "."
            return error.localizedDescription + recovery
        }
    }

    private mutating func execute(_ operation: HelperOperation) throws {
        switch operation {
        case .mkdir(let path):
            let target = try HelperPath(path, access: .write, missing: true, boundary: boundary)
            try permit(operation, [target])
            guard target.expected == nil else { throw HelperFailure("The destination already exists.") }
            let output = try stage(in: target.parent, entry: "new")
            try check(mkdirat(output.directory.fd, output.entry, 0o755), "Could not create the folder")
            output.present = true
            try publish(output, to: target)
        case .link(let text, let path):
            let target = try HelperPath(path, access: .write, missing: true, boundary: boundary)
            try permit(operation, [target])
            guard target.expected == nil else { throw HelperFailure("The destination already exists.") }
            let output = try stage(in: target.parent, entry: "new")
            try check(symlinkat(text, output.directory.fd, output.entry), "Could not create the symbolic link")
            output.present = true
            try publish(output, to: target)
        case .chmod(let path, let mode):
            let target = try HelperPath(path, access: .write, boundary: boundary)
            try permit(operation, [target])
            guard let leaf = target.leaf else { throw HelperFailure.changed }
            try target.validate(); try mutable(leaf)
            try check(fchmod(leaf.fd, mode), "Could not change permissions")
        case .chown(let path, let uid, let gid):
            let target = try HelperPath(path, access: .change, boundary: boundary)
            try permit(operation, [target])
            guard let leaf = target.leaf else { throw HelperFailure.changed }
            try target.validate(); try mutable(leaf)
            try check(fchown(leaf.fd, uid, gid), "Could not change the owner")
        case .setFlag(let path, let flag, let on):
            let target = try HelperPath(path, access: .change, boundary: boundary)
            try permit(operation, [target])
            guard let leaf = target.leaf else { throw HelperFailure.changed }
            try target.validate(); try mutable(leaf)
            let flags = try leaf.info.st_flags
            try check(fchflags(leaf.fd, on ? flags | flag : flags & ~flag), "Could not change the lock")
        case .unlock(let path):
            let target = try HelperPath(path, access: .remove, boundary: boundary)
            try permit(operation, [target])
            guard (target.expected?.st_mode ?? 0) & S_IFMT != S_IFLNK else { throw HelperFailure.changed }
            try unlock(target, device: try target.parent.info.st_dev, depth: 0)
        case .remove(let path):
            let target = try HelperPath(path, access: .remove, missing: true, boundary: boundary)
            try permit(operation, [target])
            guard target.expected != nil else { return }  // rm -f
            let captured = try capture(target)
            try removeCaptured(captured, device: target.expected!.st_dev, depth: 0)
        case .copy(let source, let destination, let recursive):
            let source = try HelperPath(source, access: .read, boundary: boundary)
            let target = try HelperPath(destination, access: .write, missing: true, boundary: boundary)
            try permit(operation, [source, target])
            guard recursive || (source.expected?.st_mode ?? 0) & S_IFMT != S_IFDIR else { throw HelperFailure("A folder requires a recursive copy.") }
            try rejectFolder(target)
            try rejectDescendant(target, of: source)
            let output = try stage(in: target.parent, entry: "new")
            output.present = true
            try copy(source, into: output.directory, name: output.entry, device: source.expected!.st_dev, depth: 0)
            let previous = target.expected == nil ? nil : try capture(target)
            try publish(output, to: target)
            if let previous { try removeCaptured(previous, device: target.expected!.st_dev, depth: 0) }
        case .move(let source, let destination, let noReplace):
            let source = try HelperPath(source, access: .remove, boundary: boundary)
            let target = try HelperPath(destination, access: .write, missing: true, boundary: boundary)
            try permit(operation, [source, target])
            try rejectFolder(target)
            try rejectDescendant(target, of: source)
            if noReplace, target.expected != nil { return }
            guard source.expected.map(HelperIdentity.init) != target.expected.map(HelperIdentity.init) else {
                throw HelperFailure("The source and destination refer to the same item.")
            }
            let captured = try capture(source)
            let previous = target.expected == nil ? nil : try capture(target)
            try target.validateParent()
            boundary(HelperBoundary(phase: .beforePublish, path: target.display))
            try target.validateParent()
            let result = move(captured.directory.fd, captured.entry, target.parent.fd, target.name, UInt32(RENAME_EXCL))
            if result == 0 {
                captured.present = false; captured.finishEmpty()
            } else if errno == EXDEV {
                throw HelperFailure(
                    "The helper cannot move an item across volumes atomically. Copy it first, then remove the original after checking the copy.")
            } else {
                throw HelperFailure.system("Could not move the item")
            }
            if let previous { try removeCaptured(previous, device: target.expected!.st_dev, depth: 0) }
        }
    }

    private func rejectFolder(_ target: HelperPath) throws {
        if let expected = target.expected, expected.st_mode & S_IFMT == S_IFDIR {
            throw HelperFailure("The destination is a folder. Nothing was placed inside it.")
        }
    }

    private func rejectDescendant(_ target: HelperPath, of source: HelperPath) throws {
        guard let expected = source.expected, expected.st_mode & S_IFMT == S_IFDIR else { return }
        var current = try HelperDescriptor(dup(target.parent.fd))
        for _ in 0..<256 {
            let identity = try HelperIdentity(current.info)
            guard identity != HelperIdentity(expected) else { throw HelperFailure("A folder cannot be placed inside itself.") }
            let parent = try HelperDescriptor(openat(current.fd, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            if try HelperIdentity(parent.info) == identity { return }
            current = parent
        }
        throw HelperFailure("The containing folders are too deep for this request.")
    }

    private mutating func stage(in parent: HelperDescriptor, entry: String, original: HelperPath? = nil) throws -> HelperStage {
        let stage = try HelperStage(parent: parent, entry: entry, original: original)
        stages.append(stage)
        return stage
    }

    private mutating func capture(_ path: HelperPath) throws -> HelperStage {
        guard let expected = path.expected else { throw HelperFailure.changed }
        try path.validate()
        let captured = try stage(in: path.parent, entry: "item", original: path)
        boundary(HelperBoundary(phase: .beforeCapture, path: path.display))
        try path.validateParent()
        try check(renameatx_np(path.parent.fd, path.name, captured.directory.fd, captured.entry, UInt32(RENAME_EXCL)), "Could not secure the item")
        captured.present = true
        boundary(HelperBoundary(phase: .afterCapture, path: path.display))
        guard let actual = try HelperPath.statAt(captured.directory.fd, captured.entry, missing: false),
            HelperIdentity(actual) == HelperIdentity(expected)
        else {
            throw HelperFailure.changed
        }
        return captured
    }

    private func publish(_ output: HelperStage, to target: HelperPath) throws {
        try target.validateParent()
        let root = try HelperPath(parent: output.directory, name: output.entry, display: output.recoveryPath)
        let flags = try root.leaf!.info.st_flags
        let movable = flags & ~UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        if flags != movable { try check(fchflags(root.leaf!.fd, movable), "Could not prepare the completed copy") }
        boundary(HelperBoundary(phase: .beforePublish, path: target.display))
        try target.validateParent()
        try check(renameatx_np(output.directory.fd, output.entry, target.parent.fd, target.name, UInt32(RENAME_EXCL)), "Could not publish the item")
        output.present = false
        output.finishEmpty()
        if flags != movable { try check(fchflags(root.leaf!.fd, flags), "Could not restore the copied lock flags") }
    }

    private mutating func enter(_ leaf: HelperDescriptor, device: dev_t, depth: Int) throws -> stat {
        let info = try leaf.info
        guard info.st_dev == device, depth < 256, entries < 1_000_000 else {
            throw HelperFailure("A volume boundary or traversal limit was reached.")
        }
        entries += 1
        guard !stages.contains(where: { (try? HelperIdentity($0.directory.info)) == HelperIdentity(info) }) else {
            throw HelperFailure("A temporary output folder was encountered inside the source.")
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard visited.insert(HelperIdentity(info)).inserted else { throw HelperFailure("A directory was encountered more than once.") }
        }
        return info
    }

    private func mutable(_ leaf: HelperDescriptor) throws {
        let info = try leaf.info
        guard info.st_mode & S_IFMT == S_IFDIR || info.st_nlink == 1 else {
            throw HelperFailure("Permissions or flags were not changed on a file with more than one name.")
        }
    }

    private mutating func unlock(_ path: HelperPath, device: dev_t, depth: Int) throws {
        guard let leaf = path.leaf else { throw HelperFailure.changed }
        try path.validate()
        let info = try enter(leaf, device: device, depth: depth)
        try mutable(leaf)
        try check(fchflags(leaf.fd, info.st_flags & ~UInt32(UF_IMMUTABLE | SF_IMMUTABLE)), "Could not clear the lock")
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in try HelperPath.names(leaf) {
                let child = try HelperPath(parent: leaf, name: name, display: path.display + "/" + name)
                try unlock(child, device: device, depth: depth + 1)
            }
        }
    }

    private mutating func removeCaptured(_ captured: HelperStage, device: dev_t, depth: Int) throws {
        let path = try HelperPath(parent: captured.directory, name: captured.entry, display: captured.recoveryPath)
        let info = try enter(path.leaf!, device: device, depth: depth)
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in try HelperPath.names(path.leaf!) {
                let child = try HelperPath(parent: path.leaf!, name: name, display: path.display + "/" + name)
                let childCapture = try capture(child)
                try removeCaptured(childCapture, device: device, depth: depth + 1)
            }
        }
        try check(
            unlinkat(captured.directory.fd, captured.entry, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0), "Could not remove the secured item")
        captured.present = false
        captured.finishEmpty()
        // Completed children must release their descriptors now, not after an entire large tree is removed.
        stages.removeAll { !$0.present }
    }

    private mutating func copy(_ source: HelperPath, into directory: HelperDescriptor, name: String, device: dev_t, depth: Int) throws {
        try source.validate()
        let leaf = source.leaf!, before = try enter(leaf, device: device, depth: depth)
        switch before.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let count = readlinkat(source.parent.fd, source.name, &buffer, buffer.count)
            guard count >= 0, count < buffer.count else { throw HelperFailure.system("Could not read the symbolic link") }
            buffer[count] = 0
            try source.validate()
            try check(buffer.withUnsafeBufferPointer { symlinkat($0.baseAddress!, directory.fd, name) }, "Could not copy the symbolic link")
        case S_IFDIR:
            try check(mkdirat(directory.fd, name, 0o700), "Could not create the copied folder")
            let output = try HelperDescriptor(openat(directory.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            for child in try HelperPath.names(leaf) {
                let input = try HelperPath(parent: leaf, name: child, display: source.display + "/" + child)
                try copy(input, into: output, name: child, device: device, depth: depth + 1)
            }
            try check(fcopyfile(leaf.fd, output.fd, nil, copyfile_flags_t(COPYFILE_METADATA)), "Could not preserve folder metadata")
        default:
            let output = try HelperDescriptor(openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            try check(fcopyfile(leaf.fd, output.fd, nil, copyfile_flags_t(COPYFILE_ALL)), "Could not copy the file")
            try check(fsync(output.fd), "Could not finish the copied file")
        }
        let after = try leaf.info
        guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw HelperFailure("The source changed while it was copied.")
        }
        try source.validate()
    }

    /// Only generated output, beneath private staging, is cleaned here. Captured user objects always restore.
    private func removeOwned(_ directory: HelperDescriptor, _ name: String) throws {
        guard let info = try HelperPath.statAt(directory.fd, name, missing: true) else { return }
        let leaf = try HelperDescriptor(
            openat(directory.fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (info.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW)))
        _ = fchflags(leaf.fd, 0)
        if info.st_mode & S_IFMT == S_IFDIR {
            for child in try HelperPath.names(leaf) { try removeOwned(leaf, child) }
        }
        try check(unlinkat(directory.fd, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0), "Could not clean up the temporary copy")
    }

    private func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else { throw HelperFailure.system(operation) }
    }
}

/// Same-volume capture makes the namespace-to-object transition atomic; only private names are then deleted.
private final class HelperStage {
    let parent: HelperDescriptor
    let directory: HelperDescriptor
    let name = ".porpoise-helper-" + UUID().uuidString
    let entry: String
    let original: HelperPath?
    var present = false
    var recoveryPath: String { (directory.path ?? "(opened temporary folder)") + "/" + entry }

    init(parent: HelperDescriptor, entry: String, original: HelperPath?) throws {
        self.parent = parent; self.entry = entry; self.original = original
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw HelperFailure.system("Could not secure a temporary folder") }
        let opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else {
            let reason = HelperFailure.system("Could not open the temporary folder")
            _ = unlinkat(parent.fd, name, AT_REMOVEDIR)
            throw reason
        }
        directory = try HelperDescriptor(opened)
        guard try directory.info.st_uid == geteuid(), let acl = acl_init(0) else { throw HelperFailure.changed }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(directory.fd, acl) == 0, fchmod(directory.fd, 0o700) == 0 else {
            throw HelperFailure.system("Could not make the temporary folder private")
        }
        let record = Recovery(
            version: 1, kind: original == nil ? "generated output" : "captured original", entry: entry,
            originalPath: original?.display, originalName: original?.name, parentPath: parent.path,
            parentIdentity: try HelperIdentity(parent.info), stageIdentity: try HelperIdentity(directory.info),
            originalIdentity: original?.expected.map(HelperIdentity.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        let file = try HelperDescriptor(openat(directory.fd, "recovery.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(file.fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HelperFailure.system("Could not record the recovery information") }
                written += count
            }
        }
        guard fsync(file.fd) == 0, fsync(directory.fd) == 0 else { throw HelperFailure.system("Could not retain the recovery information") }
    }

    private struct Recovery: Codable {
        let version: Int
        let kind: String
        let entry: String
        let originalPath: String?
        let originalName: String?
        let parentPath: String?
        let parentIdentity: HelperIdentity
        let stageIdentity: HelperIdentity
        let originalIdentity: HelperIdentity?
    }

    func restore() {
        guard present, let original else { return }
        if renameatx_np(directory.fd, entry, original.parent.fd, original.name, UInt32(RENAME_EXCL)) == 0 { present = false; finishEmpty() }
    }

    func finishEmpty() {
        guard !present, let current = try? HelperPath.statAt(parent.fd, name, missing: true),
            let opened = try? directory.info, HelperIdentity(current) == HelperIdentity(opened)
        else { return }
        _ = unlinkat(directory.fd, "recovery.json", 0)
        _ = unlinkat(parent.fd, name, AT_REMOVEDIR)
    }

    deinit {
        // Never recursively remove a capture on error. If rollback collided, its private folder retains the bytes.
        finishEmpty()
    }
}
