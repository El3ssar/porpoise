import CoreServices
import Foundation
import PorpoiseCore

/// Watches folders with FSEvents and reports which watched folders changed.
public final class FolderWatcher: @unchecked Sendable {
    /// FSEvents coalescing latency in seconds.
    private static let latency: CFTimeInterval = 0.15

    private var stream: FSEventStreamRef?
    private let callback: (Set<String>) -> Void
    private let recursive: Bool
    private let reportEventPaths: Bool
    private let queue = DispatchQueue(label: "porpoise.fsevents", autoreleaseFrequency: .workItem)
    /// Read by the FSEvents callback on `queue` while `watch` may run on another thread.
    private let lock = NSLock()
    private var _paths: [String] = []
    private var paths: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _paths }
        set { lock.lock(); _paths = newValue; lock.unlock() }
    }
    /// Real path (what FSEvents reports: /private/tmp for /tmp, symlinks resolved) → watched paths.
    private var _aliases: [String: [String]] = [:]
    private var aliases: [String: [String]] {
        get { lock.lock(); defer { lock.unlock() }; return _aliases }
        set { lock.lock(); _aliases = newValue; lock.unlock() }
    }

    public init(recursive: Bool = false, reportEventPaths: Bool = false, callback: @escaping (Set<String>) -> Void) {
        self.recursive = recursive
        self.reportEventPaths = reportEventPaths
        self.callback = callback
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit { stop() }

    public func watch(_ folders: [URL]) {
        let newPaths = Array(Set(folders.map { $0.standardizedFileURL.path })).sorted()
        if newPaths == paths { return }
        stop()
        paths = newPaths
        guard !newPaths.isEmpty else { return }
        var real: [String: [String]] = [:]
        for p in newPaths { real[FilePath.canonical(p), default: []].append(p) }
        aliases = real
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let map = me.aliases
            let events = Array(arr.prefix(count))
            let flags = (0..<count).map { eventFlags[$0] }
            let watched = Set(map.keys)
            let hits =
                me.recursive
                ? Set(map.keys.filter { root in events.contains { $0 == root || $0.hasPrefix(root.hasSuffix("/") ? root : root + "/") } })
                : FolderWatcher.changedFolders(events, watched: watched)
            // Events macOS coalesced, dropped or can't name: every folder they may cover is read again.
            let rescans = FolderWatcher.rescannedFolders(events, flags: flags, watched: watched)
            let all = hits.union(rescans)
            guard !all.isEmpty else { return }
            me.callback(me.reportEventPaths ? Set(events).union(rescans) : Set(all.flatMap { map[$0] ?? [] }))
        }
        stream = FSEventStreamCreate(
            nil, cb, &ctx, Array(real.keys) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    /// Watched folders affected by events on `eventPaths`: an event on an item touches its folder,
    /// an event on a watched folder itself touches only that folder.
    static func changedFolders(_ eventPaths: [String], watched: Set<String>) -> Set<String> {
        var changed = Set<String>()
        for p in eventPaths {
            changed.insert(p)
            if !watched.contains(p) { changed.insert((p as NSString).deletingLastPathComponent) }
        }
        return changed.intersection(watched)
    }

    /// Watched folders that events with these flags say must be read again: everything under a "must scan
    /// subdirectories" path, every watched folder when events were dropped (by the user's process or the kernel),
    /// and a watched folder whose own path changed (it, or a folder above it, was moved or renamed).
    static func rescannedFolders(_ eventPaths: [String], flags: [FSEventStreamEventFlags], watched: Set<String>) -> Set<String> {
        var out = Set<String>()
        for (p, f) in zip(eventPaths, flags) {
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { return watched }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                out.formUnion(watched.filter { $0 == p })
            }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                let root = p.hasSuffix("/") ? p : p + "/"
                out.formUnion(watched.filter { $0 == p || $0.hasPrefix(root) })
            }
        }
        return out
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            // Let a callback already running on the queue finish before `self` may go away.
            if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
        }
        stream = nil
        paths = []
        aliases = [:]
    }

    private static let queueKey = DispatchSpecificKey<Bool>()
}
