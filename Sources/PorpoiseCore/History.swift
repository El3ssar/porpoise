import Foundation
import CoreServices

/// Back/forward history of one view (each pane of each tab has its own, like Dolphin).
public struct NavigationHistory: Sendable {
    /// Oldest entries are dropped beyond this.
    public static let maxEntries = 100

    public private(set) var entries: [URL]
    public private(set) var index: Int

    public init(start: URL) {
        entries = [start]
        index = 0
    }

    public var current: URL { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }
    /// Most recent first, for the Back dropdown.
    public var backList: [URL] { Array(entries[..<index].reversed()) }
    public var forwardList: [URL] { Array(entries[(index + 1)...]) }

    public mutating func visit(_ url: URL) {
        if url == current { return }
        entries.removeSubrange((index + 1)...)
        entries.append(url)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        index = entries.count - 1
    }

    @discardableResult public mutating func goBack(_ steps: Int = 1) -> URL? {
        guard steps > 0, index - steps >= 0 else { return nil }
        index -= steps
        return current
    }

    @discardableResult public mutating func goForward(_ steps: Int = 1) -> URL? {
        guard steps > 0, index + steps < entries.count else { return nil }
        index += steps
        return current
    }
}

/// Watches folders with FSEvents and reports which watched folders changed.
public final class FolderWatcher: @unchecked Sendable {
    /// FSEvents coalescing latency in seconds.
    private static let latency: CFTimeInterval = 0.15

    private var stream: FSEventStreamRef?
    private let callback: (Set<String>) -> Void
    private let queue = DispatchQueue(label: "porpoise.fsevents")
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

    public init(callback: @escaping (Set<String>) -> Void) {
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
        for p in newPaths { real[Self.realPath(p), default: []].append(p) }
        aliases = real
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let map = me.aliases
            let hits = FolderWatcher.changedFolders(Array(arr.prefix(count)), watched: Set(map.keys))
            if !hits.isEmpty { me.callback(Set(hits.flatMap { map[$0] ?? [] })) }
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, Array(real.keys) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                                              kFSEventStreamCreateFlagUseCFTypes |
                                                              kFSEventStreamCreateFlagNoDefer))
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

    /// realpath(3): resolves every symlink, including /tmp and /var (which Foundation keeps as they are).
    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    private static let queueKey = DispatchSpecificKey<Bool>()
}
