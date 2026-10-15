import Darwin
import Foundation

/// A bounded physical read: FIFOs, devices and symlinks never reach Foundation's potentially blocking readers.
enum RegularFileData {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        while data.count <= limit {
            let chunk = try file.read(upToCount: min(256 * 1024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw CocoaError(.fileReadTooLarge)
    }
}
