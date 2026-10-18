import Foundation
import PorpoiseCore

/// One physical-node policy for displayed folder sizes and transfer size fallbacks. No file contents are read.
public enum TreeMeasure {
    public enum Policy: Sendable { case logical, allocated }
    public struct Progress: Equatable, Sendable {
        public var bytes: Int64 = 0
        public var files = 0
        /// Includes selected root folders.
        public var folders = 0
        public var errors: [String] = []
        public var items: Int { files + folders }
        public init() {}
    }

    /// Selected links may represent their targets; descendant links are never traversed. Hard links count once.
    /// Cancellation returns nil, never a successful partial total. Progress runs serially on the caller's worker.
    public static func measure(
        _ urls: [URL], policy: Policy = .logical, followTopLevelLink: Bool = true, crossVolumes: Bool = false, maxDepth: Int = .max,
        cancellation: DiskCancellation = DiskCancellation(), reportInterval: TimeInterval = 0.25, progress: @escaping (Progress) -> Void = { _ in }
    ) -> Progress? {
        let local = urls.filter(\.isFileURL)
        let roots = followTopLevelLink ? local.map { URL(fileURLWithPath: FilePath.canonical($0.path)) } : local
        let lock = NSLock()
        var total = Progress(), seen: Set<DiskIdentity> = []
        var lastReport = ProcessInfo.processInfo.systemUptime
        let scan = PhysicalTreeScanner.scan(
            roots, crossVolumes: crossVolumes, maxDepth: maxDepth, cancellation: cancellation, parallelism: 1, retainEntries: false,
            onEntry: { entry in
                lock.withLock {
                    guard !cancellation.isCancelled, seen.insert(entry.identity).inserted else { return }
                    if entry.directory {
                        total.folders += 1
                    } else {
                        total.files += 1
                        if !entry.symlink { total.bytes += policy == .logical ? entry.size : entry.allocated }
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastReport >= reportInterval && !cancellation.isCancelled {
                        progress(total); lastReport = now
                    }
                }
            })
        total.errors = scan.errors
        return scan.cancelled ? nil : total
    }
}
