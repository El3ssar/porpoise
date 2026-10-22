import CLibArchive
import Darwin
import Foundation
import PorpoiseCore
import UniformTypeIdentifiers

/// An in-memory table of safe entries. Building it never creates a folder or writes archive contents.
struct ArchiveIndex {
    struct Limits {
        var entries = 250_000
        var entryBytes: Int64 = 8 * 1024 * 1024 * 1024
        var totalBytes: Int64 = 64 * 1024 * 1024 * 1024
        var ratio: Int64 = 1_000
    }
    struct Entry: Equatable {
        let path: String
        let directory: Bool
        let size: Int64
        let modified: Date
    }
    let archive: URL
    let version: ArchiveVersion
    let entries: [String: Entry]
    let children: [String: [String]]
    let limits: Limits

    init(_ url: URL, limits: Limits = Limits(), checkpoint: () throws -> Void = {}) throws {
        let reader = try ArchiveReader(url)
        var table: [String: Entry] = [:]
        var total: Int64 = 0
        var count = 0
        while let raw = try reader.next() {
            try checkpoint()
            count += 1
            guard count <= limits.entries else { throw ArchiveFailure.limit }
            if let entry = try Self.entry(raw, limits: limits) {
                if let previous = table[entry.path], !previous.directory || !entry.directory {
                    throw ArchiveFailure.invalid("Duplicate entry “\(entry.path)”.")
                }
                table[entry.path] = entry
                let sum = total.addingReportingOverflow(entry.size)
                guard !sum.overflow, sum.partialValue <= limits.totalBytes else { throw ArchiveFailure.limit }
                total = sum.partialValue
                // A small allowance permits ordinary tiny ZIP files without making small bomb headers useful.
                guard total / max(1, reader.version.size) <= limits.ratio || total <= 1024 * 1024 else { throw ArchiveFailure.limit }
            }
            try reader.skip()
        }
        // Fill missing directory records, and reject a file used as a directory. Bound synthetic directories too.
        for entry in Array(table.values) {
            let parts = entry.path.split(separator: "/")
            var parent = ""
            for part in parts.dropLast() {
                parent += parent.isEmpty ? String(part) : "/" + part
                if let existing = table[parent] {
                    guard existing.directory else { throw ArchiveFailure.invalid("A file is used as a folder: “\(parent)”.") }
                } else {
                    guard table.count < limits.entries else { throw ArchiveFailure.limit }
                    table[parent] = Entry(path: parent, directory: true, size: 0, modified: entry.modified)
                }
            }
        }
        var children: [String: [String]] = [:]
        for entry in table.values {
            let parent = entry.path.lastIndex(of: "/").map { String(entry.path[..<$0]) } ?? ""
            children[parent, default: []].append(entry.path)
        }
        try reader.unchanged(url)
        self.archive = url; self.version = reader.version; self.entries = table; self.children = children; self.limits = limits
    }

    static func entry(_ raw: OpaquePointer, limits: Limits) throws -> Entry? {
        guard let bytes = archive_entry_pathname_utf8(raw), let name = String(validatingCString: bytes), name.utf8.count <= 4096,
            !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
            !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw ArchiveFailure.invalid("An entry has an unsafe or unreadable path.") }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), components.count <= 65 else { throw ArchiveFailure.limit }
        let normalized = components.filter { !$0.isEmpty && $0 != "." }
        guard normalized.count <= 64 else { throw ArchiveFailure.limit }
        let path = normalized.joined(separator: "/")
        guard archive_entry_symlink(raw) == nil, archive_entry_hardlink(raw) == nil else {
            throw ArchiveFailure.invalid("Links inside archives are not supported safely.")
        }
        let type = archive_entry_filetype(raw)
        guard type == S_IFREG || type == S_IFDIR, archive_entry_is_encrypted(raw) == 0 else {
            throw ArchiveFailure.invalid("Encrypted files and special entries are not supported.")
        }
        if path.isEmpty {
            guard type == S_IFDIR else { throw ArchiveFailure.invalid("An entry has an empty path.") }
            return nil
        }
        let size = type == S_IFDIR ? 0 : archive_entry_size(raw)
        guard type == S_IFDIR || archive_entry_size_is_set(raw) != 0, size >= 0, size <= limits.entryBytes else { throw ArchiveFailure.limit }
        return Entry(path: path, directory: type == S_IFDIR, size: size, modified: Date(timeIntervalSince1970: Double(archive_entry_mtime(raw))))
    }

    func list(_ path: String, at root: URL) throws -> [FileItem] {
        guard path.isEmpty || entries[path]?.directory == true else { throw CocoaError(.fileReadNoSuchFile) }
        var types: [String: String] = [:]
        return (children[path] ?? []).compactMap { key in
            guard let e = entries[key] else { return nil }
            let name = (key as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let type: String?
            if e.directory {
                type = UTType.folder.identifier
            } else if let known = types[ext] {
                type = known.isEmpty ? nil : known
            } else {
                type = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.identifier
                types[ext] = type ?? ""
            }
            return FileItem(
                url: root.appendingPathComponent(key, isDirectory: e.directory), name: name, isDirectory: e.directory,
                isHidden: name.hasPrefix("."), size: e.size, modificationDate: e.modified, contentType: type,
                posixPermissions: e.directory ? 0o555 : 0o444,
                isWritable: false)
        }
    }

    /// Extract exactly the requested file/subtree, or all entries for the explicit whole-archive fallback.
    /// The private staging directory has no archive-supplied links. Files use O_EXCL|O_NOFOLLOW, never tar's
    /// path interpretation, permissions, ACLs or xattrs. Only a completed, version-checked result is published.
    func extract(_ selected: String?, into folder: URL, name: String, checkpoint: () throws -> Void = {}) throws -> URL {
        if let selected, entries[selected] == nil { throw CocoaError(.fileReadNoSuchFile) }
        try RemoteFS.checkName(name)
        let reader = try ArchiveReader(archive)
        guard reader.version == version else { throw ArchiveFailure.changed }
        try checkpoint()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".porpoise-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent(name)
        if selected == nil || selected.flatMap({ entries[$0] })?.directory == true {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        }
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while let raw = try reader.next() {
            try checkpoint()
            guard let entry = try Self.entry(raw, limits: limits) else { try reader.skip(); continue }
            guard entries[entry.path] == entry || (entry.directory && entries[entry.path]?.directory == true) else { throw ArchiveFailure.changed }
            let wanted = selected == nil || entry.path == selected || (selected.map { entry.path.hasPrefix($0 + "/") } ?? false)
            guard wanted else { try reader.skip(); continue }
            guard seen.insert(entry.path).inserted || entry.directory else { throw ArchiveFailure.changed }
            let relative: String
            if let selected {
                relative = entry.path == selected ? "" : String(entry.path.dropFirst(selected.count + 1))
            } else {
                relative = entry.path
            }
            let target = relative.isEmpty ? output : output.appendingPathComponent(relative)
            if entry.directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try reader.skip()
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            do {
                defer { close(fd) }
                var written: Int64 = 0
                while true {
                    try checkpoint()
                    let count = archive_read_data(reader.handle, &buffer, buffer.count)
                    guard count >= 0 else { throw reader.failure() }
                    if count == 0 { break }
                    guard Int64(count) <= entry.size - written else { throw ArchiveFailure.limit }
                    try Shell.currentTransferControl?.pace(Int64(count))
                    written += Int64(count)
                    try buffer.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < count {
                            let n = write(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                            if n < 0, errno == EINTR { continue }
                            guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                            offset += n
                        }
                    }
                    Shell.currentTransferControl?.onBytes(Int64(count))
                }
                guard written == entry.size else { throw ArchiveFailure.invalid("An entry has a truncated body.") }
            }
        }
        let expected = entries.values.filter { e in
            !e.directory && (selected == nil || e.path == selected || (selected.map { e.path.hasPrefix($0 + "/") } ?? false))
        }
        guard expected.allSatisfy({ seen.contains($0.path) }) else { throw ArchiveFailure.changed }
        try reader.unchanged(archive)
        try checkpoint()
        let destination = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RemoteError.exists(name) }
        try FileManager.default.moveItem(at: output, to: destination)
        return destination
    }
}
