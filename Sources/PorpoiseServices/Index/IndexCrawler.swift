import Darwin
import Foundation
import PorpoiseCore

/// Physical walk: never follows symlinks or crosses into a volume the user has not explicitly selected.
/// getattrlistbulk reads a whole folder's names, types, sizes and dates in one call; folders are read by several
/// threads at once, then the entries are added depth-first (each subtree one contiguous range of ids).
public enum IndexCrawler {
    public static func crawl(
        _ root: String, exclusions: [String], content: Bool = false, cancelled: () -> Bool = { false },
        unreadable: (String) -> Void = { _ in }, skip: (String) -> Bool = { _ in false }
    ) -> NameIndex {
        var index = NameIndex()
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return index }
        let excluded = { (path: String) in exclusions.contains { FilePath.contains(path: path, in: $0) } }
        return withoutActuallyEscaping(cancelled) { cancelled in
            withoutActuallyEscaping(skip) { skip in
                if cancelled() || skip(root) || excluded(root) { return index }
                let mode = rootStat.st_mode & S_IFMT
                guard mode == S_IFDIR || mode == S_IFLNK || mode == S_IFREG else { return index }
                let walk = Walk(
                    device: rootStat.st_dev, content: content, cancelled: cancelled, skip: { skip($0) || excluded($0) })
                let top = Listing(path: root)
                let grams = mode == S_IFREG && content && rootStat.st_size <= Walk.contentLimit ? Walk.grams(root) : nil
                let rootId = index.append(
                    parent: NameIndex.noParent, name: Array(root.utf8), folded: Array(IndexQuery.fold((root as NSString).lastPathComponent).utf8),
                    size: Int64(rootStat.st_size), mtime: UInt32(clamping: rootStat.st_mtimespec.tv_sec), directory: mode == S_IFDIR,
                    symlink: mode == S_IFLNK, contentGrams: grams)
                guard mode == S_IFDIR else { return index }
                walk.run(top)
                for path in walk.unreadable.sorted() { unreadable(path) }
                if cancelled() { return index }
                let size = top.treeSize()
                index.reserveCapacity(
                    entries: size.entries, foldedBytes: size.foldedBytes, nameBytes: size.nameBytes, namedEntries: size.namedEntries)
                add(top, under: rootId, to: &index)
                if content { index.prepareContent() }
                return index
            }
        }
    }

    /// Adds `listing` and everything below it, depth-first: each entry, then its folder's contents. Each folder's
    /// listing is let go of once it's in the index, so the walk's copy of the tree shrinks as the index grows.
    static func add(_ listing: Listing, under parent: UInt32, to index: inout NameIndex) {
        var stack: [(Listing, Int, UInt32)] = [(listing, 0, parent)]
        while !stack.isEmpty {
            let (l, i, p) = stack.removeLast()
            guard i < l.entries.count else {
                l.release()
                continue
            }
            stack.append((l, i + 1, p))
            let e = l.entries[i]
            let name = Array(l.bytes[Int(e.nameStart)..<Int(e.nameStart + e.nameLength)])
            let folded = e.foldedStart < 0 ? nil : Array(l.bytes[Int(e.foldedStart)..<Int(e.foldedStart) + Int(e.foldedLength)])
            var grams: [UInt32]?
            if e.grams >= 0 { swap(&grams, &l.grams[Int(e.grams)]) }
            let id = index.append(
                parent: p, name: name, folded: folded, size: e.size, mtime: e.mtime, directory: e.directory, symlink: e.symlink,
                contentGrams: grams)
            if e.sub >= 0 { stack.append((l.subfolders[Int(e.sub)], 0, id)) }
        }
    }

    /// One folder as read: its entries packed in a few arrays (no object per file).
    final class Listing: @unchecked Sendable {
        struct Entry {
            var nameStart: UInt32
            var nameLength: UInt32
            /// -1: the name is its own folded form.
            var foldedStart: Int32
            var foldedLength: UInt32
            var size: Int64
            var mtime: UInt32
            var directory: Bool
            var symlink: Bool
            /// Index in `subfolders` of this entry's own listing, -1 when it isn't read (a file, a package…).
            var sub: Int32
            /// Index in `grams` of the file's text trigrams, -1 when its text isn't indexed.
            var grams: Int32
        }
        let path: String
        var bytes: [UInt8] = []
        var entries: [Entry] = []
        var subfolders: [Listing] = []
        /// nil once added to the index.
        var grams: [[UInt32]?] = []
        init(path: String) { self.path = path }

        /// Entries below this folder and the bytes of their names: what the index needs room for.
        func treeSize() -> (entries: Int, foldedBytes: Int, nameBytes: Int, namedEntries: Int) {
            var size = (entries: 0, foldedBytes: 0, nameBytes: 0, namedEntries: 0)
            var pending = [self]
            while let l = pending.popLast() {
                size.entries += l.entries.count
                for e in l.entries {
                    if e.foldedStart < 0 {
                        size.foldedBytes += Int(e.nameLength)
                    } else {
                        size.foldedBytes += Int(e.foldedLength)
                        size.nameBytes += Int(e.nameLength)
                        size.namedEntries += 1
                    }
                }
                pending.append(contentsOf: l.subfolders)
            }
            return size
        }

        func release() {
            bytes = []
            entries = []
            subfolders = []
            grams = []
        }
    }

    /// The folders still to read, shared by the threads reading them.
    final class Walk: @unchecked Sendable {
        static let contentLimit: Int64 = 1024 * 1024
        let device: dev_t
        let content: Bool
        let cancelled: () -> Bool
        let skip: (String) -> Bool
        private let lock = NSCondition()
        private var queue: [Listing] = []
        private var busy = 0
        private(set) var unreadable: [String] = []

        init(device: dev_t, content: Bool, cancelled: @escaping () -> Bool, skip: @escaping (String) -> Bool) {
            self.device = device
            self.content = content
            self.cancelled = cancelled
            self.skip = skip
        }

        /// Entries read on the calling thread before others help: small trees never wait on a thread pool.
        static let inlineEntries = 2000

        func run(_ top: Listing, threads: Int = min(12, max(4, ProcessInfo.processInfo.activeProcessorCount))) {
            queue = [top]
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128 * 1024, alignment: 16)
            var entries = 0
            while entries < Self.inlineEntries || queue.count < 2, !queue.isEmpty, !cancelled() {
                let next = queue.removeFirst()  // breadth-first: the queue fills up if the tree is big
                if !self.read(next, buffer: buffer) { unreadable.append(next.path) }
                queue.append(contentsOf: next.subfolders)
                entries += next.entries.count
            }
            buffer.deallocate()
            guard !queue.isEmpty, !cancelled() else { return }
            // A big tree: readers on several threads. Returns once every reader is done and has let go of the
            // closures (the caller's aren't escaping).
            let readers = min(threads, queue.count)
            if readers == 1 { return work() }
            DispatchQueue.concurrentPerform(iterations: readers) { _ in work() }
        }

        private func work() {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128 * 1024, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                lock.lock()
                while queue.isEmpty && busy > 0 { lock.wait() }
                guard let next = queue.popLast() else {
                    lock.broadcast()
                    lock.unlock()
                    return
                }
                busy += 1
                lock.unlock()
                let ok = cancelled() ? true : read(next, buffer: buffer)
                lock.lock()
                busy -= 1
                if !ok { unreadable.append(next.path) }
                if !cancelled() { queue.append(contentsOf: next.subfolders) }
                lock.broadcast()
                lock.unlock()
            }
        }

        /// Reads one folder; false when it can't be opened or read.
        func read(_ listing: Listing, buffer: UnsafeMutableRawPointer) -> Bool {
            let fd = open(listing.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var al = attrlist()
            al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            al.commonattr =
                attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_DEVID)
                | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FNDRINFO)
            al.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
            let base = listing.path == "/" ? "" : listing.path
            var failed = false
            while true {
                let n = getattrlistbulk(fd, &al, buffer, 128 * 1024, 0)
                if n < 0 { failed = true }
                if n <= 0 { break }
                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<n {
                    let length = entry.loadUnaligned(as: UInt32.self)
                    defer { entry += Int(length) }
                    parse(entry, into: listing, base: base)
                }
            }
            return !failed
        }

        private func parse(_ entry: UnsafeRawPointer, into listing: Listing, base: String) {
            var field = entry + 4
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            let common = returned.commonattr
            var error: UInt32 = 0
            if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                error = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return }
            let ref = field.loadUnaligned(as: attrreference_t.self)
            let namePtr = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
            let name = UnsafeBufferPointer(start: namePtr, count: max(0, Int(ref.attr_length) - 1))
            field += MemoryLayout<attrreference_t>.size
            guard !name.isEmpty else { return }
            let path = base + "/" + String(decoding: name, as: UTF8.self)
            if skip(path) { return }
            if error != 0 {
                if error == UInt32(EACCES) || error == UInt32(EPERM) {
                    lock.withLock { unreadable.append(path) }
                }
                return
            }
            var dev: Int32 = 0
            if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                dev = field.loadUnaligned(as: Int32.self)
                field += 4
            }
            var type: UInt32 = 0
            if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                type = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            var mtime: UInt32 = 0
            if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                mtime = UInt32(clamping: field.loadUnaligned(as: Int.self))
                field += MemoryLayout<timespec>.size
            }
            var bundleBit = false
            if common & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
                // Finder flags (big-endian) at byte 8; kHasBundle = 0x2000.
                bundleBit = UInt16(bigEndian: (field + 8).loadUnaligned(as: UInt16.self)) & 0x2000 != 0
                field += 32
            }
            var size: Int64 = 0
            if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 { size = field.loadUnaligned(as: Int64.self) }
            // Another volume mounted inside is left out; so are devices, sockets and pipes.
            guard dev == device else { return }
            let directory = type == 2, symlink = type == 5  // VDIR, VLNK
            guard directory || symlink || type == 1 else { return }  // VREG
            if directory && symlink { return }
            var sub: Int32 = -1
            if directory && !(bundleBit || Self.isPackage(name, path: path)) {
                sub = Int32(listing.subfolders.count)
                listing.subfolders.append(Listing(path: path))
            }
            var grams: Int32 = -1
            if content && type == 1 && size <= Self.contentLimit, let g = Self.grams(path) {
                grams = Int32(listing.grams.count)
                listing.grams.append(g)
            }
            let start = UInt32(listing.bytes.count)
            listing.bytes.append(contentsOf: name)
            var foldedStart: Int32 = -1, foldedLength: UInt32 = 0
            if !Self.isFolded(name) {
                let f = Array(IndexQuery.fold(String(decoding: name, as: UTF8.self)).utf8)
                foldedStart = Int32(listing.bytes.count)
                foldedLength = UInt32(f.count)
                listing.bytes.append(contentsOf: f)
            }
            listing.entries.append(
                Listing.Entry(
                    nameStart: start, nameLength: UInt32(name.count), foldedStart: foldedStart, foldedLength: foldedLength, size: size,
                    mtime: mtime, directory: directory, symlink: symlink, sub: sub, grams: grams))
        }

        /// Plain lower-case ASCII: folding leaves it as it is.
        static func isFolded(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
            for b in name where b >= 0x80 || b &- 0x41 < 26 { return false }
            return true
        }

        /// Bundles Finder shows as one item. Known extensions answer at once; other folders with an extension ask
        /// Launch Services (apps register document packages of their own).
        static let packageExtensions: Set<String> = [
            "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt",
            "component", "photoslibrary", "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace", "xcarchive", "playground",
            "pkg", "mpkg", "rtfd", "pages", "numbers", "key", "scptd", "systemextension", "dext", "action", "workflow",
        ]

        static func isPackage(_ name: UnsafeBufferPointer<UInt8>, path: String) -> Bool {
            guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return false }
            let ext = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
            if packageExtensions.contains(ext) { return true }
            return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        }

        /// The trigrams of a text file's folded contents (UTF-8 text only).
        static func grams(_ path: String) -> [UInt32]? {
            guard let text = IndexFileText.read(path, limit: Int(contentLimit)) else { return nil }
            return Array(IndexQuery.fold(text).utf8).withUnsafeBufferPointer { ContentIndex.trigrams($0) }
        }
    }
}
