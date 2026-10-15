import Darwin
import Foundation
import PorpoiseCore

public struct DiskProgress: Sendable {
    public var files: Int
    public var bytes: Int64
    public var path: String
    public init(files: Int = 0, bytes: Int64 = 0, path: String = "") { self.files = files; self.bytes = bytes; self.path = path }
}

/// Physical inventory, parallel by top-level subtree. Bulk metadata avoids one stat per ordinary entry.
public enum PhysicalTreeScanner {
    public static func entry(_ url: URL) throws -> DiskEntry {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { throw CocoaError(.fileReadUnsupportedScheme) }
        return DiskEntry(
            url: url, identity: DiskIdentity(device: st.st_dev, inode: UInt64(st.st_ino)), directory: kind == S_IFDIR,
            symlink: kind == S_IFLNK, size: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512,
            modified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9))
    }
    public static func scan(
        _ urls: [URL], crossVolumes: Bool = false, maxDepth: Int = .max,
        cancellation: DiskCancellation = DiskCancellation(), progress: @escaping (DiskProgress) -> Void = { _ in }
    ) -> DiskScan {
        let lock = NSLock(), work = OperationQueue()
        work.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.processorCount)
        var result = DiskScan(), seen: Set<DiskIdentity> = [], last = Date.distantPast, bytes: Int64 = 0
        let roots = Array(Set(urls.filter(\.isFileURL).map { URL(fileURLWithPath: IndexPath.entry($0.path)) })).sorted { $0.path < $1.path }
        func error(_ path: String, _ message: String) { lock.withLock { result.errors.append("\(path): \(message)") } }
        func add(_ entry: DiskEntry) {
            let update: DiskProgress? = lock.withLock {
                result.entries.append(entry)
                if !entry.directory && !entry.symlink { bytes += entry.size }
                if Date().timeIntervalSince(last) < 0.1 { return nil }
                last = Date(); return DiskProgress(files: result.entries.count, bytes: bytes, path: entry.url.path)
            }
            if let update { progress(update) }
        }
        func walk(_ item: DiskEntry, device: Int32, depth: Int) {
            if cancellation.isCancelled || (!crossVolumes && item.identity.device != device) { return }
            add(item)
            guard item.directory, depth < maxDepth, lock.withLock({ seen.insert(item.identity).inserted }) else { return }
            do {
                for child in try children(item.url, cancellation: cancellation) {
                    if cancellation.isCancelled { return }
                    walk(child, device: device, depth: depth + 1)
                }
            } catch let err { error(item.url.path, err.localizedDescription) }
        }
        // Drop roots already traversed by a selected ancestor on the same device.
        let entries = roots.compactMap { url -> DiskEntry? in
            do { return try entry(url) } catch let err { error(url.path, err.localizedDescription); return nil }
        }
        let unique = entries.filter { child in
            !entries.contains { ancestor in
                ancestor.directory && ancestor.url != child.url && (crossVolumes || ancestor.identity.device == child.identity.device)
                    && NameIndex.contains(path: child.url.path, in: ancestor.url.path)
            }
        }
        for root in unique {
            if cancellation.isCancelled { break }
            if root.directory && maxDepth > 0 {
                add(root)
                lock.withLock { _ = seen.insert(root.identity) }
                do {
                    let children = try children(root.url, cancellation: cancellation)
                    let partitions = min(4, children.count)
                    for partition in 0..<partitions {
                        work.addOperation {
                            for i in stride(from: partition, to: children.count, by: partitions) {
                                if cancellation.isCancelled { return }
                                walk(children[i], device: root.identity.device, depth: 1)
                            }
                        }
                    }
                } catch let err { error(root.url.path, err.localizedDescription) }
            } else {
                walk(root, device: root.identity.device, depth: 0)
            }
        }
        work.waitUntilAllOperationsAreFinished()
        result.cancelled = cancellation.isCancelled
        result.entries.sort { $0.url.path < $1.url.path }
        progress(DiskProgress(files: result.entries.count, bytes: bytes, path: ""))
        return result
    }

    private static func children(_ folder: URL, cancellation: DiskCancellation) throws -> [DiskEntry] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        attrs.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), items: [DiskEntry] = []
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &attrs, $0.baseAddress!, $0.count, 0) }
            if count == 0 { return items }
            if count < 0 { return try posixChildren(folder, cancellation: cancellation) }
            do {
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    for _ in 0..<count {
                        guard offset + 24 <= raw.count else { throw CocoaError(.fileReadCorruptFile) }
                        let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        guard length >= 24, length <= raw.count - offset else { throw CocoaError(.fileReadCorruptFile) }
                        let entry = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
                        let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                        var cursor = 24
                        func read<T>(_ type: T.Type) throws -> T {
                            guard cursor + MemoryLayout<T>.size <= entry.count else { throw CocoaError(.fileReadCorruptFile) }
                            defer { cursor += MemoryLayout<T>.size }
                            return entry.loadUnaligned(fromByteOffset: cursor, as: T.self)
                        }
                        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { throw CocoaError(.fileReadCorruptFile) }
                        let referenceOffset = cursor
                        let ref = try read(attrreference_t.self)
                        let nameOffset = referenceOffset + Int(ref.attr_dataoffset), nameLength = Int(ref.attr_length)
                        guard nameOffset >= 0, nameLength > 0, nameOffset <= entry.count, nameLength <= entry.count - nameOffset else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        let name = String(decoding: entry[nameOffset..<(nameOffset + nameLength - 1)], as: UTF8.self)
                        var device: Int32 = 0, kind: UInt32 = 0, modified = timespec(), inode: UInt64 = 0, allocated: Int64 = 0, size: Int64 = 0
                        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 { device = try read(Int32.self) }
                        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { kind = try read(UInt32.self) }
                        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 { modified = try read(timespec.self) }
                        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { inode = try read(UInt64.self) }
                        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { allocated = try read(Int64.self) }
                        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 { size = try read(Int64.self) }
                        let url = folder.appendingPathComponent(name)
                        if inode == 0 || device == 0 || kind == 0 {
                            if let fallback = try? self.entry(url) { items.append(fallback) }
                        } else if kind == 1 || kind == 2 || kind == 5 {
                            items.append(
                                DiskEntry(
                                    url: url, identity: DiskIdentity(device: device, inode: inode), directory: kind == 2, symlink: kind == 5,
                                    size: max(0, size), allocated: max(0, allocated),
                                    modified: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)))
                        }
                        offset += length
                    }
                }
            } catch { return try posixChildren(folder, cancellation: cancellation) }
        }
    }
    private static func posixChildren(_ folder: URL, cancellation: DiskCancellation) throws -> [DiskEntry] {
        guard let dir = opendir(folder.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(dir) }
        var items: [DiskEntry] = []
        while let ent = readdir(dir) {
            try cancellation.check()
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let url = folder.appendingPathComponent(name)
            do { items.append(try entry(url)) } catch let err {
                if (err as? CocoaError)?.code != .fileReadUnsupportedScheme { throw err }
            }
        }
        return items
    }
}
