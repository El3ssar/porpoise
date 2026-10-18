import CoreServices
import Foundation
import PorpoiseCore

/// Owns its stream for exactly the stream lifetime.
final class IndexEvents {
    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }
    static let exclusionLimit = 8
    private var stream: FSEventStreamRef?
    var available: Bool { stream != nil }
    private let queue = DispatchQueue(label: "app.porpoise.index-events", qos: .utility, autoreleaseFrequency: .workItem)

    /// What the stream calls. The stream holds it (retained with the stream, released when the stream goes), so a
    /// callback that starts while IndexEvents is being freed on another queue never touches the freed object.
    private final class Handler {
        let callback: ([String], UInt64, Bool) -> Void
        init(_ callback: @escaping ([String], UInt64, Bool) -> Void) { self.callback = callback }
    }

    /// FSEvents reports nothing in `excluding`, up to `exclusionLimit` folders inside the roots (more are ignored here,
    /// and filtered by the caller).
    init(roots: [String], since: UInt64, excluding: [String] = [], callback: @escaping ([String], UInt64, Bool) -> Void) {
        let handler = Handler(callback)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, ids in
                guard let info else { return }
                let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
                var rescan = false, last: UInt64 = 0
                var changed: [String] = []
                for i in 0..<count {
                    if flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                    changed.append(names[i])
                    last = max(last, ids[i])
                    let lost = UInt32(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
                    if flags[i] & lost != 0 { rescan = true }
                }
                if !changed.isEmpty { handler.callback(changed, last, rescan) }
            }, &context, roots as CFArray, since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.1, flags)
        if let stream {
            let excluded = excluding.filter { path in roots.contains { $0 != path && FilePath.contains(path: path, in: $0) } }
            if !excluded.isEmpty { FSEventStreamSetExclusionPaths(stream, Array(excluded.prefix(Self.exclusionLimit)) as CFArray) }
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
