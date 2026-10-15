import Darwin
import Foundation

/// Bounded reads of physical regular files. A concurrently replaced symlink/FIFO or growing file cannot
/// make the indexer follow an unselected tree, block waiting for a writer, or allocate an unbounded buffer.
enum IndexFileText {
    static func read(_ path: String, limit: Int) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit || chunk.contains(0) { return nil }
            }
        } catch { return nil }
        return String(data: data, encoding: .utf8)
    }
}
