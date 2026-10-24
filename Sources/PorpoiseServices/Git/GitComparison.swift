import Darwin
import Foundation
import PorpoiseCore

/// Private, bounded snapshots for the existing comparison window. Neither side writes to the repository.
public final class GitComparison: @unchecked Sendable {
    public let left: URL
    public let right: URL
    private let directory: URL
    deinit { try? FileManager.default.removeItem(at: directory) }
    /// Walk from the repository descriptor without following any changed directory symlink.
    private static func openFile(_ path: String, root: URL) throws -> Int32 {
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw GitCommand.Failure.command }
        defer { close(directory) }
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw GitCommand.Failure.command }
            close(directory); directory = next
        }
        return openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    public init(item: FileItem, status: GitFolderStatus) throws {
        guard !item.isDirectory, !item.isSymlink, item.name == item.url.lastPathComponent, let path = status.relativePath(for: item.url),
            let kind = status.snapshot.status(for: path, directory: false), kind != .ignored
        else { throw GitCommand.Failure.command }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        left = directory.appendingPathComponent("HEAD-" + item.name)
        right = directory.appendingPathComponent("Working-" + item.name)
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + GitStatusService.budget
            let before: Data
            if kind == .untracked || kind == .added {
                before = Data()
            } else {
                let original = status.snapshot.originalPaths[path] ?? path
                before = try GitCommand.run(["show", "--no-ext-diff", "--no-textconv", "HEAD:" + original], in: status.root, deadline: deadline)
            }
            try before.write(to: left)
            var after = Data()
            if kind != .deleted {
                // No symlink following, FIFOs or devices. Never read beyond the comparison's 16 MiB budget.
                let fd = try Self.openFile(path, root: status.root)
                guard fd >= 0 else { throw GitCommand.Failure.command }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16 * 1024 * 1024 else {
                    throw GitCommand.Failure.budget
                }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCommand.Failure.budget }
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 { break }
                    guard count > 0, after.count + count <= 16 * 1024 * 1024 else { throw GitCommand.Failure.budget }
                    after.append(contentsOf: buffer.prefix(count))
                }
            }
            try after.write(to: right)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
