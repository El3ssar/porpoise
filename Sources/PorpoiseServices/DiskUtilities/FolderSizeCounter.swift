import Foundation
import PorpoiseCore

/// Logical bytes and item counts for Properties. Call on a private worker queue; callbacks run there too.
public enum FolderSizeCounter {
    public struct Progress: Equatable, Sendable {
        public var bytes: Int64 = 0
        public var files = 0
        /// Includes selected root folders; the presentation may subtract a single selected root.
        public var folders = 0
        public var items: Int { files + folders }
        public init() {}
    }

    /// A cancelled traversal returns nil, never a successful partial total. No file contents are read.
    public static func count(
        _ urls: [URL], cancellation: DiskCancellation, reportInterval: TimeInterval = 0.25,
        progress: (Progress) -> Void = { _ in }
    ) -> Progress? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        var total = Progress()
        var lastReport = ProcessInfo.processInfo.systemUptime
        @discardableResult
        func add(_ url: URL) -> URLResourceValues? {
            // A window reuses its selection URLs. Discard Foundation's cached file size on every scan.
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: keys) else { return nil }
            if values.isDirectory == true && values.isSymbolicLink != true {
                total.folders += 1
            } else {
                total.files += 1
                total.bytes += Int64(values.fileSize ?? 0)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= reportInterval && !cancellation.isCancelled {
                progress(total)
                lastReport = now
            }
            return values
        }
        for url in urls {
            guard !cancellation.isCancelled else { return nil }
            let values = add(url)
            guard !cancellation.isCancelled else { return nil }
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            else { continue }
            while !cancellation.isCancelled, let child = entries.nextObject() as? URL {
                add(child)
            }
        }
        return cancellation.isCancelled ? nil : total
    }
}
